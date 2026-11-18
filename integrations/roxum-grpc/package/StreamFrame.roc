import GrpcStatus

StreamFrame := [].{
	State : { pending : List(U8), remaining : [Prefix, Body(U64)], messages : U64, payload : U64 }

	start : U64, U64 -> StreamFrame.State
	start = |messages, payload| { pending: [], remaining: Prefix, messages, payload }

	# Consume at most one envelope so the handler can deliver it before reading the next.
	read : StreamFrame.State, List(U8), U64 -> Try([Partial(StreamFrame.State), Message(List(U8), StreamFrame.State, List(U8))], (GrpcStatus.Code, Str))
	read = |frame, chunk, maximum| {
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
				read(next, rest, maximum)
			}
		}
	}

	at_boundary = |state| state.remaining == Prefix and state.pending.is_empty()
}

expect {
	# Split inside the prefix, at the prefix/body boundary and inside the body.
	bytes = [0.U8, 0, 0, 0, 3, 10, 11, 12]
	var $ok = Bool.True
	for split in [1.U64, 2, 3, 4, 5, 6, 7] {
		match StreamFrame.read(StreamFrame.start(2.U64, 3.U64), bytes.take_first(split), 3)? {
			Partial(frame) => {
				rest = bytes.drop_first(split).concat([0, 0, 0, 0, 0])
				$ok = $ok and StreamFrame.read(frame, rest, 3) == Ok(Message([10, 11, 12], StreamFrame.start(1, 0), [0, 0, 0, 0, 0]))
			}
			Message(_, _, _) => {
				$ok = Bool.False
			}
		}
	}
	$ok
}
