## A media type for a `Content-Type` field, such as `application/pdf`.
##
## A string literal whose expected type is `MediaType` is checked at compile time,
## so `Reply.bytes(data, "application/pdf")` cannot carry a misspelled form. A value
## computed at run time goes through `from_str`.
MediaType :: Str.{
	is_eq : _

	## Converts a plain string literal.
	from_quote : Str -> Try(MediaType, [BadQuotedBytes(Str)])
	from_quote = |raw|
		match MediaType.from_str(raw) {
			Ok(value) => Ok(value)
			Err(InvalidMediaType) => Err(BadQuotedBytes("a media type is type/subtype, with optional ; parameters"))
		}

	## Converts a string computed at run time, such as a type stored with an upload.
	from_str : Str -> Try(MediaType, [InvalidMediaType])
	from_str = |raw| {
		pieces = Str.split_on(raw, ";")
		essence = Str.split_on(List.first(pieces) ?? "", "/")
		valid = match essence {
			[type_name, subtype] => is_token(type_name) and is_token(subtype)
			_ => Bool.False
		}
		if valid and List.all(List.drop_first(pieces, 1), is_parameter) {
			Ok(MediaType.(raw))
		} else {
			Err(InvalidMediaType)
		}
	}

	inner : MediaType -> Str
	inner = |MediaType.(value)| value
}

is_token = |text| {
	bytes = text.to_utf8()
	!List.is_empty(bytes) and List.all(bytes, is_token_byte)
}

is_token_byte = |byte|
	(byte >= 'a' and byte <= 'z')
		or (byte >= 'A' and byte <= 'Z')
		or (byte >= '0' and byte <= '9')
		or List.contains("!#$%&'*+-.^_`|~".to_utf8(), byte)

## A parameter's value may be quoted; control bytes are refused either way.
is_parameter = |text|
	match Str.split_first(Str.trim(text), "=") {
		Ok({ before, after }) =>
			is_token(before)
				and !Str.is_empty(after)
				and List.all(after.to_utf8(), |byte| byte >= 32 and byte != 127)
		Err(NotFound) => Bool.False
	}

expect MediaType.from_str("application/pdf") == Ok(MediaType.("application/pdf"))
expect MediaType.from_str("text/csv; charset=utf-8") == Ok(MediaType.("text/csv; charset=utf-8"))
expect MediaType.from_str("application/vnd.api+json") == Ok(MediaType.("application/vnd.api+json"))
expect MediaType.from_str("") == Err(InvalidMediaType)
expect MediaType.from_str("pdf") == Err(InvalidMediaType)
expect MediaType.from_str("application/") == Err(InvalidMediaType)
expect MediaType.from_str("/pdf") == Err(InvalidMediaType)
expect MediaType.from_str("a/b/c") == Err(InvalidMediaType)
expect MediaType.from_str("a b/c") == Err(InvalidMediaType)
expect MediaType.from_str("text/csv; charset") == Err(InvalidMediaType)
expect MediaType.from_str("text/csv; charset=") == Err(InvalidMediaType)
expect MediaType.from_str("text/csv\r\nx: y") == Err(InvalidMediaType)
