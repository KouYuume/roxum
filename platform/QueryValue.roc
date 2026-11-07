import PercentEncoding

## A percent-encoded URI query component, for building URLs. It is not the
## type of an incoming request query.
##
## Every UTF-8 byte except the RFC 3986 unreserved characters `A-Z a-z 0-9 - . _ ~`
## is encoded with uppercase hex, including `&`, `=`, `#`, `+`, and `%`. The
## whole value is encoded, so `"key=${value}"` also encodes the `=`; build each
## key and value separately and join them with `=` and `&` outside this type.
QueryValue :: { encoded : Str }.{
	is_eq : _

	## Converts a string literal typed as `QueryValue`. It always succeeds.
	from_quote : Str -> Try(QueryValue, [BadQuotedBytes(Str)])
	from_quote = |raw| Ok(QueryValue.({ encoded: PercentEncoding.encode(raw) }))

	## Converts an interpolated string typed as `QueryValue`. The literal parts and
	## interpolated values are joined first, then encoded as one value.
	from_interpolation : List(Str) -> Try((List(Str) -> QueryValue), [InvalidInterpolation(Str)])
	from_interpolation = |segments|
		Str.from_interpolation(segments).map_ok(|assemble| |values| QueryValue.({ encoded: PercentEncoding.encode(assemble(values)) }))

	## The encoded text.
	inner : QueryValue -> Str
	inner = |QueryValue.(value)| value.encoded
}

expect {
	value : QueryValue
	value = "AZaz09-._~"
	QueryValue.inner(value) == "AZaz09-._~"
}

expect {
	value : QueryValue
	value = "a b&c=d#e+f"
	QueryValue.inner(value) == "a%20b%26c%3Dd%23e%2Bf"
}

expect {
	dynamic = "a&b=鵬"
	value : QueryValue
	value = "before=${dynamic}"
	QueryValue.inner(value) == "before%3Da%26b%3D%E9%B5%AC"
}
