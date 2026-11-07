PercentEncoding :: [].{
	encode = |value| {
		var $encoded = []
		for byte in value.to_utf8() {
			if PercentEncoding.is_unreserved(byte) {
				$encoded = List.append($encoded, byte)
			} else {
				$encoded = List.append($encoded, '%')
				$encoded = List.append($encoded, PercentEncoding.hex_digit(byte // 16))
				$encoded = List.append($encoded, PercentEncoding.hex_digit(byte % 16))
			}
		}
		Str.from_utf8_lossy($encoded)
	}

	is_unreserved = |byte|
		(byte >= 'A' and byte <= 'Z')
			or (byte >= 'a' and byte <= 'z')
			or (byte >= '0' and byte <= '9')
			or byte == '-'
			or byte == '.'
			or byte == '_'
			or byte == '~'

	hex_digit = |nibble|
		if nibble < 10 { '0' + nibble } else { 'A' + nibble - 10 }
}

expect PercentEncoding.encode("/09:") == "%2F09%3A"
expect PercentEncoding.encode("@AZ[") == "%40AZ%5B"
expect PercentEncoding.encode("`az{") == "%60az%7B"
expect PercentEncoding.encode(",-./") == "%2C-.%2F"
expect PercentEncoding.encode("^_`") == "%5E_%60"
expect PercentEncoding.encode("}~\u(7F)") == "%7D~%7F"
expect PercentEncoding.encode("鵬") == "%E9%B5%AC"
expect PercentEncoding.encode("") == ""
expect PercentEncoding.encode("%2F") == "%252F"
expect PercentEncoding.encode("\u(0)") == "%00"
