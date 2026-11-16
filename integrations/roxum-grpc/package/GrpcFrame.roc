## Finite Unary framing. HTTP DATA boundaries are not message boundaries.
GrpcFrame := [].{
	Error : [MissingMessage, Truncated, InvalidFlag, UnsupportedCompression, MessageLimit, ExtraMessage]

	decode_unary : List(U8), U64 -> Try(List(U8), GrpcFrame.Error)
	decode_unary = |bytes, maximum| {
		if bytes.is_empty() {
			return Err(MissingMessage)
		}
		if bytes.len() < 5 {
			return Err(Truncated)
		}
		flag = bytes.get(0) ?? 0
		if flag > 1 {
			return Err(InvalidFlag)
		}
		if flag == 1 {
			return Err(UnsupportedCompression)
		}
		var $size = 0.U64
		for byte in bytes.sublist({ start: 1, len: 4 }) {
			$size = $size * 256 + byte.to_u64()
		}
		if $size > maximum {
			return Err(MessageLimit)
		}
		if bytes.len() - 5 < $size {
			return Err(Truncated)
		}
		if bytes.len() - 5 > $size {
			return Err(ExtraMessage)
		}
		Ok(bytes.drop_first(5))
	}

	encode : List(U8), U64 -> Try(List(U8), [MessageLimit])
	encode = |bytes, maximum| {
		size = bytes.len()
		if size > maximum or size > 4294967295 {
			return Err(MessageLimit)
		}
		Ok([0, (size / 16777216).to_u8_wrap(), (size / 65536).to_u8_wrap(), (size / 256).to_u8_wrap(), size.to_u8_wrap()].concat(bytes))
	}
}

expect GrpcFrame.decode_unary([], 0) == Err(MissingMessage)
expect GrpcFrame.decode_unary([0, 0, 0, 0], 0) == Err(Truncated)
expect GrpcFrame.decode_unary([0, 0, 0, 0, 0], 0) == Ok([])
expect GrpcFrame.decode_unary([0, 0, 0, 0, 1], 1) == Err(Truncated)
expect GrpcFrame.decode_unary([0, 0, 0, 0, 0, 0], 1) == Err(ExtraMessage)
expect GrpcFrame.decode_unary([1, 0, 0, 0, 0], 0) == Err(UnsupportedCompression)
expect GrpcFrame.decode_unary([2, 0, 0, 0, 0], 0) == Err(InvalidFlag)
expect GrpcFrame.decode_unary([0, 255, 255, 255, 255], 64) == Err(MessageLimit)
expect {
	var $ok = Bool.True
	for length in [63.U64, 64, 65] {
		bytes = List.repeat(7.U8, length)
		result = GrpcFrame.encode(bytes, 64)
		$ok = $ok and if length > 64 {
			result == Err(MessageLimit)
		} else {
			GrpcFrame.decode_unary(result?, 64) == Ok(bytes)
		}
	}
	$ok
}

# Big-endian length transitions are checked without allocating declared bodies.
expect {
	var $ok = Bool.True
	for size in [255.U64, 256, 257, 65535, 65536, 65537, 16777215, 16777216, 16777217, 4294967294, 4294967295] {
		prefix = [0, (size / 16777216).to_u8_wrap(), (size / 65536).to_u8_wrap(), (size / 256).to_u8_wrap(), size.to_u8_wrap()]
		$ok = $ok and GrpcFrame.decode_unary(prefix, size) == Err(Truncated) and GrpcFrame.decode_unary(prefix, size - 1) == Err(MessageLimit)
	}
	$ok
}
expect {
	var $ok = Bool.True
	for size in [255.U64, 256, 257] {
		bytes = List.repeat(42.U8, size)
		frame = GrpcFrame.encode(bytes, 257)?
		$ok = $ok and GrpcFrame.decode_unary(frame, 257) == Ok(bytes)
	}
	$ok
}
