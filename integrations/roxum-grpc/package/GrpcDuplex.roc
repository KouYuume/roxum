import pf.Handler
import pf.HeaderName
import pf.Reply
import pf.RequestExecution
import pf.ResponseHeader
import pf.ResponseWriter
import GrpcServerStream
import GrpcFrame
import GrpcMetadata
import GrpcStatus
import GrpcTimeout
import GrpcUnary
import GrpcWire
import StreamFrame

## Incremental bidirectional framing for typed HTTP/2 streaming routes.
GrpcDuplex := [].{
	Callbacks(model, state, input, output) : {
		begin! : model, List(GrpcMetadata.Entry) => Try({ state : state, initial : List(GrpcMetadata.Entry) }, GrpcUnary.Failure),
		receive! : state, [End, Message(input)] => Try(state, GrpcUnary.Failure),
		next! : state => Try([Read, Send(output, state), Finish(List(GrpcMetadata.Entry))], GrpcUnary.Failure),
	}

	handler : (List(U8) -> Try(input, decode_err)), (output, U64 -> Try(List(U8), encode_err)), GrpcDuplex.Callbacks(model, state, input, output), GrpcServerStream.Limits -> Handler(model, tag, provided)
	handler = |decode, encode, callbacks, limits| Handler.duplex({
		begin!: |model, head| {
			metadata = GrpcWire.request_metadata(head.version, head.method, head.headers, limits.metadata).map_err(GrpcWire.reject_request)?
			duration = GrpcTimeout.streaming_duration(head.headers, limits.duration_nanoseconds).map_err(|_| rejection(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "invalid grpc-timeout"), limits))?
			prepared = (callbacks.begin!)(model, metadata).map_err(|problem| rejection(problem, limits))?
			headers = GrpcWire.initial_fields(prepared.initial, limits.metadata).map_err(|_| rejection(GrpcUnary.failure(GrpcStatus.Code.Internal, "invalid initial metadata"), limits))?
			expiry = terminal(GrpcStatus.Code.DeadlineExceeded, "deadline exceeded", [], { status_bytes: 128, metadata: GrpcMetadata.defaults })
			RequestExecution.limit_with_trailers!(duration, expiry).map_err(|_| Reply.status(500))?
			state = { service: prepared.state, frame: StreamFrame.start(limits.messages, limits.payload_bytes), ended: Bool.False, waiting_for_input: Bool.False, pending: [], partial: Bool.False, deferred: None, messages: limits.messages, payload: limits.payload_bytes }
			Ok({ state, interest: Handler.Interest.Both, status: 200, headers: headers.prepend(ResponseHeader.{ name: HeaderName.("content-type"), value: "application/grpc+proto" }) })
		},
		ready!: |state, event, writer| {
			var $state = state
			if state.deferred == None {
				match receive!(state, event.input, decode, callbacks.receive!, limits.request_bytes) {
					Ok(next) => {
						$state = next
					}
					Err(problem) => {
						fields = failure_fields(problem, limits)
						if !state.partial {
							return Ok(Handler.DuplexNext.Finish(fields))
						}
						# Complete the already started envelope before its terminal status.
						$state = { ..state, deferred: Some(fields) }
					}
				}
			}
			if !$state.pending.is_empty() and event.writable {
				part = $state.pending.take_first(16384)
				match ResponseWriter.try_write!(writer, part).map_err(|_| StreamClosed)? {
					Accepted => {
						rest = $state.pending.drop_first(part.len())
						$state = { ..$state, pending: rest, partial: !rest.is_empty() }
					}
					Pending => {}
				}
			}
			if $state.pending.is_empty() {
				match $state.deferred {
					Some(fields) => return Ok(Handler.DuplexNext.Finish(fields))
					None => {}
				}
				if $state.waiting_for_input {
					return Ok(Handler.DuplexNext.Await({ state: $state, interest: Handler.Interest.Read }))
				}
				match (callbacks.next!)($state.service) {
					Err(problem) => return Ok(Handler.DuplexNext.Finish(failure_fields(problem, limits)))
					Ok(Finish(trailing)) => return Ok(Handler.DuplexNext.Finish(terminal(GrpcStatus.Code.Ok, "", trailing, limits)))
					Ok(Read) => {
						if $state.ended {
							return Ok(Handler.DuplexNext.Finish(failure_fields(GrpcUnary.failure(GrpcStatus.Code.Internal, "read after request EOF"), limits)))
						}
						return Ok(Handler.DuplexNext.Await({ state: { ..$state, waiting_for_input: Bool.True }, interest: Handler.Interest.Read }))
					}
					Ok(Send(value, service)) => {
						match prepare_output(value, encode, limits.response_bytes, $state.messages, $state.payload) {
							Err(problem) => return Ok(Handler.DuplexNext.Finish(failure_fields(problem, limits)))
							Ok(output) => {
								$state = { ..$state, service, pending: output.frame, messages: $state.messages - 1, payload: $state.payload - output.size }
							}
						}
					}
				}
			}
			interest = if $state.ended or $state.deferred != None {
				Handler.Interest.Write
			} else {
				Handler.Interest.Both
			}
			Ok(Handler.DuplexNext.Await({ state: $state, interest }))
		},
	})
}

prepare_output = |value, encode, maximum, messages, payload| {
	if messages == 0 {
		return Err(GrpcUnary.failure(GrpcStatus.Code.ResourceExhausted, "message count limit"))
	}
	bytes = encode(value, maximum).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.Internal, "response encoding failed"))?
	if bytes.len() > payload {
		return Err(GrpcUnary.failure(GrpcStatus.Code.ResourceExhausted, "payload limit"))
	}
	frame = GrpcFrame.encode(bytes, maximum).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.ResourceExhausted, "message limit"))?
	Ok({ frame, size: bytes.len() })
}

receive! = |state, input, decode, step!, maximum| {
	match input {
		Idle => Ok(state)
		Failed(reason) => Err(
			GrpcUnary.failure(
				match reason {
					TooLarge => GrpcStatus.Code.ResourceExhausted
					TimedOut => GrpcStatus.Code.DeadlineExceeded
					BadRequest => GrpcStatus.Code.InvalidArgument
					_ => GrpcStatus.Code.Internal
				},
				"request input failed",
			),
		)
		End => {
			if !StreamFrame.at_boundary(state.frame) {
				return Err(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "truncated request envelope"))
			}
			service = step!(state.service, End)?
			Ok({ ..state, service, ended: Bool.True, waiting_for_input: Bool.False })
		}
		Chunk(chunk) => {
			var $frame = state.frame
			var $service = state.service
			var $waiting = state.waiting_for_input
			var $chunk = chunk
			while !$chunk.is_empty() {
				match StreamFrame.read($frame, $chunk, maximum).map_err(|(code, msg)| GrpcUnary.failure(code, msg))? {
					Partial(frame) => return Ok({ ..state, service: $service, frame, waiting_for_input: $waiting })
					Message(bytes, frame, rest) => {
						value = decode(bytes).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "invalid Protobuf message"))?
						$service = step!($service, Message(value))?
						$waiting = Bool.False
						$frame = frame
						$chunk = rest
					}
				}
			}
			Ok({ ..state, service: $service, frame: $frame, waiting_for_input: $waiting })
		}
	}
}

terminal = |code, message, trailing, limits| GrpcWire.terminal_fields(code, message, trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? (GrpcWire.terminal_fields(GrpcStatus.Code.Internal, "invalid application status", [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? [])

failure_fields = |GrpcUnary.Failure.(failure), limits| if failure.code == GrpcStatus.Code.Ok {
	terminal(GrpcStatus.Code.Internal, "invalid application status", [], { status_bytes: 128, metadata: GrpcMetadata.defaults })
} else {
	terminal(failure.code, failure.message, failure.trailing, limits)
}

rejection = |GrpcUnary.Failure.(failure), limits| GrpcWire.failure(failure.code, failure.message, failure.trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? (GrpcWire.failure(GrpcStatus.Code.Internal, "invalid application status", [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500))
