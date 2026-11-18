import StreamFrame
import pf.Handler
import pf.Reply
import GrpcMetadata
import GrpcStatus
import GrpcUnary
import GrpcWire

## Incrementally reduce a sequence of request messages to one finite response.
GrpcClientStream := [].{
	Consumer(input, output) := {
		message! : input => Try(GrpcClientStream.Consumer(input, output), GrpcUnary.Failure),
		finish! : {} => Try(GrpcUnary.Response(output), GrpcUnary.Failure),
	}

	consume = |state, step!, finish!| GrpcClientStream.Consumer.(
		{
			message!: |message| {
				next = step!(state, message)?
				Ok(GrpcClientStream.consume(next, step!, finish!))
			},
			finish!: |{}| finish!(state),
		},
	)

	handler = |decode, encode, begin!, limits| Handler.streaming({
		begin!: |model, head| {
			metadata = GrpcWire.request_metadata(head.version, head.method, head.headers, limits.metadata).map_err(GrpcWire.reject_request)?
			consumer = begin!(model, metadata).map_err(|problem| failure(problem, limits))?
			Ok({ consumer, frame: StreamFrame.start(limits.messages, limits.payload_bytes) })
		},
		chunk!: |state, chunk| {
			var $frame = state.frame
			var $consumer = state.consumer
			var $chunk = chunk
			while !$chunk.is_empty() {
				match StreamFrame.read($frame, $chunk, limits.request_bytes).map_err(|(code, message)| error_reply(code, message))? {
					Partial(partial) => return Ok({ consumer: $consumer, frame: partial })
					Message(bytes, next, rest) => {
						$consumer = deliver!($consumer, bytes, decode, limits)?
						$frame = next
						$chunk = rest
					}
				}
			}
			Ok({ consumer: $consumer, frame: $frame })
		},
		done!: |_model, state| {
			if !StreamFrame.at_boundary(state.frame) {
				return Err(error_reply(GrpcStatus.Code.InvalidArgument, "truncated request envelope"))
			}
			GrpcClientStream.Consumer.(consumer) = state.consumer
			GrpcUnary.Response.(response) = (consumer.finish!)({}).map_err(|problem| failure(problem, limits))?
			bytes = encode(response.message, limits.response_bytes).map_err(|_| error_reply(GrpcStatus.Code.Internal, "response encoding failed"))?
			GrpcWire.success(bytes, response.initial, response.trailing, { message_bytes: limits.response_bytes, metadata: limits.metadata }).map_err(|_| error_reply(GrpcStatus.Code.Internal, "invalid response metadata"))
		},
	})
}

deliver! = |GrpcClientStream.Consumer.(consumer), bytes, decode, limits| {
	message = decode(bytes).map_err(|_| error_reply(GrpcStatus.Code.InvalidArgument, "invalid Protobuf message"))?
	(consumer.message!)(message).map_err(|problem| failure(problem, limits))
}

failure = |GrpcUnary.Failure.(problem), limits| GrpcWire.failure(problem.code, problem.message, problem.trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? error_reply(GrpcStatus.Code.Internal, "invalid application status")

error_reply = |code, message| GrpcWire.failure(code, message, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500)
