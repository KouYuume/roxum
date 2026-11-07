## Standard base64 with padding, for SCRAM messages.
Base64 := [].{
	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = List.with_capacity((bytes.len() + 2) / 3 * 4)
		var $index = 0
		while $index < bytes.len() {
			b0 = (bytes.get($index) ?? 0).to_u32()
			has1 = $index + 1 < bytes.len()
			has2 = $index + 2 < bytes.len()
			b1 = (bytes.get($index + 1) ?? 0).to_u32()
			b2 = (bytes.get($index + 2) ?? 0).to_u32()
			triple = b0.shl_wrap(16).bitwise_or(b1.shl_wrap(8)).bitwise_or(b2)
			$out = $out.append(symbol(triple.shr_zf_wrap(18)))
			$out = $out.append(symbol(triple.shr_zf_wrap(12)))
			$out = $out.append(if has1 { symbol(triple.shr_zf_wrap(6)) } else { '=' })
			$out = $out.append(if has2 { symbol(triple) } else { '=' })
			$index = $index + 3
		}
		Str.from_utf8($out) ?? ""
	}

	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| {
		chars = text.to_utf8()
		if chars.len() % 4 != 0 {
			return Err(InvalidBase64)
		}
		var $out = List.with_capacity(chars.len() / 4 * 3)
		var $index = 0
		while $index < chars.len() {
			c2 = chars.get($index + 2) ?? '='
			c3 = chars.get($index + 3) ?? '='
			v0 = value(chars.get($index) ?? 0)?
			v1 = value(chars.get($index + 1) ?? 0)?
			v2 = if c2 == '=' { 0 } else { value(c2)? }
			v3 = if c3 == '=' { 0 } else { value(c3)? }
			triple = v0.shl_wrap(18).bitwise_or(v1.shl_wrap(12)).bitwise_or(v2.shl_wrap(6)).bitwise_or(v3)
			$out = $out.append(triple.shr_zf_wrap(16).to_u8_wrap())
			if c2 != '=' {
				$out = $out.append(triple.shr_zf_wrap(8).to_u8_wrap())
			}
			if c3 != '=' {
				$out = $out.append(triple.to_u8_wrap())
			}
			$index = $index + 4
		}
		Ok($out)
	}
}

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

symbol : U32 -> U8
symbol = |sextet| alphabet.get(sextet.bitwise_and(63).to_u64()) ?? '='

value : U8 -> Try(U32, [InvalidBase64])
value = |char|
	if char >= 'A' and char <= 'Z' {
		Ok((char - 'A').to_u32())
	} else if char >= 'a' and char <= 'z' {
		Ok((char - 'a').to_u32() + 26)
	} else if char >= '0' and char <= '9' {
		Ok((char - '0').to_u32() + 52)
	} else if char == '+' {
		Ok(62)
	} else if char == '/' {
		Ok(63)
	} else {
		Err(InvalidBase64)
	}

expect Base64.encode("".to_utf8()) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.decode("Zm9vYmE=") == Ok("fooba".to_utf8())
expect Base64.decode("Zg==") == Ok("f".to_utf8())
expect Base64.decode("Zm9v!") == Err(InvalidBase64)
