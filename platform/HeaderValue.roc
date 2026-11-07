## A header field value for a response. The type is opaque and every
## constructor rejects CR and LF, so a value cannot split a header line.
## Other control characters are not rejected here; the host checks them when
## it writes the response.
##
## A string literal whose expected type is `HeaderValue` is converted by
## `from_quote`, and checked at compile time. There is no interpolation: a
## value computed at run time can contain CR or LF, and an interpolated literal
## cannot fail at run time, so build such a value with `from_str`:
##
## ```roc
## value : Try(HeaderValue, [CrlfInjection])
## value = HeaderValue.from_str("attachment; filename=${name}")
## ```
HeaderValue :: Str.{
	is_eq : _

	## Converts a plain string literal. Fails when the literal contains CR or LF.
	from_quote : Str -> Try(HeaderValue, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if HeaderValue.has_crlf(raw) {
			Err(BadQuotedBytes("header value must not contain CR or LF"))
		} else {
			Ok(HeaderValue.(raw))
		}

	## Converts a string computed at run time. Returns `Err(CrlfInjection)` when
	## it contains CR or LF.
	from_str : Str -> Try(HeaderValue, [CrlfInjection])
	from_str = |raw|
		if HeaderValue.has_crlf(raw) {
			Err(CrlfInjection)
		} else {
			Ok(HeaderValue.(raw))
		}

	## Returns the value as a string.
	inner : HeaderValue -> Str
	inner = |HeaderValue.(value)| value

	## Returns whether the string contains a CR or LF character.
	has_crlf : Str -> Bool
	has_crlf = |value| Str.contains(value, "\r") or Str.contains(value, "\n")
}

expect HeaderValue.from_str("") == Ok(HeaderValue.(""))
expect HeaderValue.from_str("visible\tvalue") == Ok(HeaderValue.("visible\tvalue"))
expect HeaderValue.from_str("\u(9)") == Ok(HeaderValue.("\u(9)"))
expect HeaderValue.from_str("\u(B)") == Ok(HeaderValue.("\u(B)"))
expect HeaderValue.from_str("\u(C)") == Ok(HeaderValue.("\u(C)"))
expect HeaderValue.from_str("\u(E)") == Ok(HeaderValue.("\u(E)"))
expect HeaderValue.from_str("before\rafter") == Err(CrlfInjection)
expect HeaderValue.from_str("before\nafter") == Err(CrlfInjection)
expect HeaderValue.from_str("\r\n") == Err(CrlfInjection)

expect {
	name = "report.pdf"
	value : Try(HeaderValue, [CrlfInjection])
	value = HeaderValue.from_str("attachment; filename=${name}")
	value == Ok(HeaderValue.("attachment; filename=report.pdf"))
}

expect {
	name = "report.pdf\r\nSet-Cookie: admin=1"
	value : Try(HeaderValue, [CrlfInjection])
	value = HeaderValue.from_str("attachment; filename=${name}")
	value == Err(CrlfInjection)
}
