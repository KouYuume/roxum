import pf.Reply
import pf.Handler
import pf.RequestBody
import GrpcDecode
import GrpcFrame
import GrpcMetadata
import GrpcStatus
import GrpcWire

## Finite typed calls. Deadlines and pre-body admission are not applied here.
GrpcUnary := [].{
	Limits : { request_bytes : U64, response_bytes : U64, status_bytes : U64, metadata : GrpcMetadata.Limits }
	Response(value) := { message : value, initial : List(GrpcMetadata.Entry), trailing : List(GrpcMetadata.Entry) }
	Failure := { code : GrpcStatus.Code, message : Str, trailing : List(GrpcMetadata.Entry) }

	response = |message| GrpcUnary.Response.{ message, initial: [], trailing: [] }
	failure = |code, message| GrpcUnary.Failure.{ code, message, trailing: [] }

	## Codec callbacks close over their own resource limits. Decode failures are
	## client errors; encode failures and invalid application metadata are internal.
	handler = |decode, encode, call!, limits| Handler.effectful(
		|model, context| {
			request = context.request
			metadata = GrpcWire.request_metadata(request.version, request.method, request.headers, limits.metadata).map_err(GrpcWire.reject_request)?
			bytes = match request.body {
				RequestBody.Bytes(body) => body
				_ => []
			}
			payload = GrpcFrame.decode_unary(bytes, limits.request_bytes).map_err(GrpcWire.reject_frame)?
			input = GrpcDecode.message!(payload, decode).map_err(|(code, message)| error_reply(code, message))?
			match call!(model, input, metadata) {
				Ok(GrpcUnary.Response.(result)) => {
					output = encode(result.message, limits.response_bytes).map_err(|_| error_reply(GrpcStatus.Code.Internal, "response encoding failed"))?
					GrpcWire.success(output, result.initial, result.trailing, { message_bytes: limits.response_bytes, metadata: limits.metadata }).map_err(|_| error_reply(GrpcStatus.Code.Internal, "invalid response metadata"))
				}
				Err(GrpcUnary.Failure.(problem)) => Err(GrpcWire.failure(problem.code, problem.message, problem.trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? error_reply(GrpcStatus.Code.Internal, "invalid application status"))
			}
		},
	)
}

error_reply = |code, message| GrpcWire.failure(code, message, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.text("gRPC response failure").with_status(500)
