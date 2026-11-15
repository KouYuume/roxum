## Internal standard Base64. Accept padding or its omission; emit no padding.
GrpcBase64 := [].{
	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = []
		var $bits = 0.U32
		var $count = 0.U8
		for byte in bytes {
			$bits = $bits.shl_wrap(8).bitwise_or(byte.to_u32())
			$count = $count + 8
			while $count >= 6 {
				$count = $count - 6
				$out = $out.append(symbol($bits.shr_zf_wrap($count)))
			}
		}
		if $count > 0 {
			$out = $out.append(symbol($bits.shl_wrap(6 - $count)))
		}
		Str.from_utf8($out) ?? ""
	}

	decode : List(U8) -> Try(List(U8), [InvalidBase64])
	decode = |bytes| {
		var $end = bytes.len()
		while $end > 0 and bytes.get($end - 1) == Ok('=') {
			$end = $end - 1
		}
		padding = bytes.len() - $end
		if padding > 2 or $end % 4 == 1 {
			return Err(InvalidBase64)
		}
		if padding > 0 and (bytes.len() % 4 != 0 or padding != (4 - $end % 4) % 4) {
			return Err(InvalidBase64)
		}
		var $out = []
		var $bits = 0.U32
		var $count = 0.U8
		for byte in bytes.take_first($end) {
			digit = value(byte)?
			$bits = $bits.shl_wrap(6).bitwise_or(digit)
			$count = $count + 6
			if $count >= 8 {
				$count = $count - 8
				$out = $out.append($bits.shr_zf_wrap($count).to_u8_wrap())
			}
		}
		if $count > 0 and $bits.bitwise_and((1.U32).shl_wrap($count) - 1) != 0 {
			return Err(InvalidBase64)
		}
		Ok($out)
	}
}

alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

symbol = |digit| alphabet.get(digit.bitwise_and(63).to_u64()) ?? 'A'

value : U8 -> Try(U32, [InvalidBase64])
value = |byte| {
	if byte >= 'A' and byte <= 'Z' {
		return Ok((byte - 'A').to_u32())
	}
	if byte >= 'a' and byte <= 'z' {
		return Ok((byte - 'a').to_u32() + 26)
	}
	if byte >= '0' and byte <= '9' {
		return Ok((byte - '0').to_u32() + 52)
	}
	if byte == '+' {
		return Ok(62)
	}
	if byte == '/' {
		return Ok(63)
	}
	Err(InvalidBase64)
}
expect GrpcBase64.encode([102]) == "Zg"
expect GrpcBase64.encode([102, 111]) == "Zm8"
expect GrpcBase64.encode([102, 111, 111]) == "Zm9v"
expect GrpcBase64.decode("Zg==".to_utf8()) == Ok([102])
expect GrpcBase64.decode("Zg".to_utf8()) == Ok([102])
expect GrpcBase64.decode("Zh".to_utf8()) == Err(InvalidBase64)
expect GrpcBase64.decode("=AAA".to_utf8()) == Err(InvalidBase64)
expect GrpcBase64.decode("AAAA=".to_utf8()) == Err(InvalidBase64)
