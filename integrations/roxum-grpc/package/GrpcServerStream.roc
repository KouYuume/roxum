import pf.Handler
import pf.HeaderName
import pf.Reply
import pf.RequestBody
import pf.RequestExecution
import pf.ResponseHeader
import pf.ResponseWriter
import GrpcDecode
import GrpcFrame
import GrpcMetadata
import GrpcStatus
import GrpcTimeout
import GrpcUnary
import GrpcWire

## One finite request and incremental, typed output. The integration owns the
## producer loop and terminal status; application code supplies one step at a time.
GrpcServerStream := [].{
	Limits : { request_bytes : U64, response_bytes : U64, status_bytes : U64, metadata : GrpcMetadata.Limits, messages : U64, payload_bytes : U64, duration_nanoseconds : U64 }
	defaults : GrpcServerStream.Limits
	defaults = { request_bytes: 2097152, response_bytes: 2097152, status_bytes: 128, metadata: GrpcMetadata.defaults, messages: 65536, payload_bytes: 67108864, duration_nanoseconds: 300000000000 }

	Producer(message) := ({} => Try([Message(message, GrpcServerStream.Producer(message)), End(List(GrpcMetadata.Entry))], GrpcUnary.Failure))
	Response(message) := { initial : List(GrpcMetadata.Entry), stream : GrpcServerStream.Producer(message) }

	## Each step returns Next(message, next_state), Done(trailing_metadata), or
	## an application failure. Only the current state and message are retained by
	## the loop; retaining history in state is the application's responsibility.
	response = |state, step!| GrpcServerStream.Response.{ initial: [], stream: unfold(state, step!) }

	handler = |decode, encode, call!, limits| Handler.effectful(
		|model, context| {
			request = context.request
			metadata = GrpcWire.request_metadata(request.version, request.method, request.headers, limits.metadata).map_err(GrpcWire.reject_request)?
			duration = GrpcTimeout.streaming_duration(request.headers, limits.duration_nanoseconds).map_err(|_| error_reply(GrpcStatus.Code.InvalidArgument, "invalid grpc-timeout"))?
			bytes = match request.body {
				RequestBody.Bytes(body) => body
				_ => []
			}
			payload = GrpcFrame.decode_unary(bytes, limits.request_bytes).map_err(GrpcWire.reject_frame)?
			input = GrpcDecode.message!(payload, decode).map_err(|(code, message)| error_reply(code, message))?
			GrpcServerStream.Response.(prepared) = call!(model, input, metadata).map_err(|GrpcUnary.Failure.(problem)| GrpcWire.failure(problem.code, problem.message, problem.trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? error_reply(GrpcStatus.Code.Internal, "invalid application status"))?
			headers = GrpcWire.initial_fields(prepared.initial, limits.metadata).map_err(|_| error_reply(GrpcStatus.Code.Internal, "invalid response metadata"))?
			expiry = GrpcWire.terminal_fields(GrpcStatus.Code.DeadlineExceeded, "deadline exceeded", [], { status_bytes: 128, metadata: GrpcMetadata.defaults }).map_err(|_| Reply.status(500))?
			RequestExecution.limit_with_trailers!(duration, expiry).map_err(|_| error_reply(GrpcStatus.Code.Internal, "execution control unavailable"))?
			Ok(Reply.stream(|writer| send!(writer, prepared.stream, encode, limits)).with_headers(headers.prepend(ResponseHeader.{ name: HeaderName.("content-type"), value: "application/grpc+proto" })))
		},
	)
}

unfold = |state, step!| GrpcServerStream.Producer.(
	|{}| match step!(state) {
		Ok(Next(message, rest)) => Ok(Message(message, unfold(rest, step!)))
		Ok(Done(trailing)) => Ok(End(trailing))
		Err(problem) => Err(problem)
	},
)

send! = |writer, stream, encode, limits| {
	var $stream = stream
	var $messages = 0.U64
	var $bytes = 0.U64
	while Bool.True {
		GrpcServerStream.Producer.(next!) = $stream
		match next!({}) {
			Err(GrpcUnary.Failure.(problem)) => return finish!(writer, problem.code, problem.message, problem.trailing, limits, Bool.False)
			Ok(End(trailing)) => return finish!(writer, GrpcStatus.Code.Ok, "", trailing, limits, Bool.True)
			Ok(Message(message, rest)) => {
				if $messages >= limits.messages {
					return finish!(writer, GrpcStatus.Code.ResourceExhausted, "message count limit", [], limits, Bool.False)
				}
				output = match encode(message, limits.response_bytes) {
					Ok(value) => value
					Err(_) => return finish!(writer, GrpcStatus.Code.Internal, "response encoding failed", [], limits, Bool.False)
				}
				if output.len() > limits.payload_bytes - $bytes {
					return finish!(writer, GrpcStatus.Code.ResourceExhausted, "payload limit", [], limits, Bool.False)
				}
				frame = match GrpcFrame.encode(output, limits.response_bytes) {
					Ok(value) => value
					Err(_) => return finish!(writer, GrpcStatus.Code.ResourceExhausted, "message limit", [], limits, Bool.False)
				}
				ResponseWriter.write!(writer, frame)?
				$messages = $messages + 1
				$bytes = $bytes + output.len()
				$stream = rest
			}
		}
	}
}

finish! = |writer, code, message, trailing, limits, success| {
	fields = if !success and code == GrpcStatus.Code.Ok {
		Err(InvalidStatus)
	} else {
		GrpcWire.terminal_fields(code, message, trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata })
	}
	terminal = fields ?? (GrpcWire.terminal_fields(GrpcStatus.Code.Internal, "invalid application status", [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? [])
	ResponseWriter.finish!(writer, terminal).map_err(|_| StreamClosed)
}

error_reply = |code, message| GrpcWire.failure(code, message, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500)
