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
			Ok({ consumer, frame: start(limits.messages, limits.payload_bytes) })
		},
		chunk!: |state, chunk| {
			var $frame = state.frame
			var $consumer = state.consumer
			var $chunk = chunk
			while !$chunk.is_empty() {
				match read_frame($frame, $chunk, limits.request_bytes).map_err(|(code, message)| error_reply(code, message))? {
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
			if state.frame.remaining != Prefix or !state.frame.pending.is_empty() {
				return Err(error_reply(GrpcStatus.Code.InvalidArgument, "truncated request envelope"))
			}
			GrpcClientStream.Consumer.(consumer) = state.consumer
			GrpcUnary.Response.(response) = (consumer.finish!)({}).map_err(|problem| failure(problem, limits))?
			bytes = encode(response.message, limits.response_bytes).map_err(|_| error_reply(GrpcStatus.Code.Internal, "response encoding failed"))?
			GrpcWire.success(bytes, response.initial, response.trailing, { message_bytes: limits.response_bytes, metadata: limits.metadata }).map_err(|_| error_reply(GrpcStatus.Code.Internal, "invalid response metadata"))
		},
	})
}

Frame : { pending : List(U8), remaining : [Prefix, Body(U64)], messages : U64, payload : U64 }

start : U64, U64 -> Frame
start = |messages, payload| { pending: [], remaining: Prefix, messages, payload }

# Consume at most one envelope so the handler can deliver it before reading the next.
read_frame : Frame, List(U8), U64 -> Try([Partial(Frame), Message(List(U8), Frame, List(U8))], (GrpcStatus.Code, Str))
read_frame = |frame, chunk, maximum| {
	size = match frame.remaining {
		Prefix => 5
		Body(total) => total
	}
	part = chunk.take_first(size - frame.pending.len())
	buffer = frame.pending.concat(part)
	if buffer.len() < size {
		return Ok(Partial({ ..frame, pending: buffer }))
	}
	rest = chunk.drop_first(part.len())
	match frame.remaining {
		Body(_) => Ok(Message(buffer, { ..frame, pending: [], remaining: Prefix }, rest))
		Prefix => {
			flag = buffer.get(0) ?? 0
			if flag == 1 {
				return Err((GrpcStatus.Code.Unimplemented, "compressed messages are unsupported"))
			}
			if flag > 1 {
				return Err((GrpcStatus.Code.InvalidArgument, "invalid envelope flag"))
			}
			var $length = 0.U64
			for byte in buffer.drop_first(1) {
				$length = $length * 256 + byte.to_u64()
			}
			if frame.messages == 0 or $length > maximum or $length > frame.payload {
				return Err((GrpcStatus.Code.ResourceExhausted, "request stream limit"))
			}
			next = { pending: [], remaining: Body($length), messages: frame.messages - 1, payload: frame.payload - $length }
			read_frame(next, rest, maximum)
		}
	}
}

expect {
	# Split inside the prefix, at the prefix/body boundary and inside the body.
	bytes = [0.U8, 0, 0, 0, 3, 10, 11, 12]
	var $ok = Bool.True
	for split in [1.U64, 2, 3, 4, 5, 6, 7] {
		match read_frame(start(2.U64, 3.U64), bytes.take_first(split), 3)? {
			Partial(frame) => {
				rest = bytes.drop_first(split).concat([0, 0, 0, 0, 0])
				$ok = $ok and read_frame(frame, rest, 3) == Ok(Message([10, 11, 12], start(1, 0), [0, 0, 0, 0, 0]))
			}
			Message(_, _, _) => {
				$ok = Bool.False
			}
		}
	}
	$ok
}

deliver! = |GrpcClientStream.Consumer.(consumer), bytes, decode, limits| {
	message = decode(bytes).map_err(|_| error_reply(GrpcStatus.Code.InvalidArgument, "invalid Protobuf message"))?
	(consumer.message!)(message).map_err(|problem| failure(problem, limits))
}

failure = |GrpcUnary.Failure.(problem), limits| GrpcWire.failure(problem.code, problem.message, problem.trailing, { status_bytes: limits.status_bytes, metadata: limits.metadata }) ?? error_reply(GrpcStatus.Code.Internal, "invalid application status")

error_reply = |code, message| GrpcWire.failure(code, message, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500)
