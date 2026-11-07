import PercentEncoding

## One percent-encoded URI path segment, for building links and redirect
## targets. It is not the type of an incoming request path.
##
## Every UTF-8 byte except the RFC 3986 unreserved characters `A-Z a-z 0-9 - . _ ~`
## is encoded with uppercase hex, including `/`, `?`, `#`, and `%`. Input that
## is already percent-encoded is therefore encoded again. The unencoded value
## must not be empty or exactly `.` or `..`: an empty segment would turn
## `"/${a}/${b}"` into `//host...`, which a browser reads as another host.
##
## ```roc
## segment : PathSegment
## segment = "reports"
##
## dynamic : PathSegment
## dynamic = "user-${name}"
##
## computed : Try(PathSegment, [DotSegment, EmptySegment])
## computed = PathSegment.from_str(name)
## ```
PathSegment :: { encoded : Str }.{
	is_eq : _

	## Converts a string literal typed as `PathSegment`. An empty literal, `.`, or
	## `..` is a compile-time error.
	from_quote : Str -> Try(PathSegment, [BadQuotedBytes(Str)])
	from_quote = |raw|
		match PathSegment.from_str(raw) {
			Ok(value) => Ok(value)
			Err(DotSegment) => Err(BadQuotedBytes("path segment must not be . or .."))
			Err(EmptySegment) => Err(BadQuotedBytes("path segment must not be empty"))
		}

	## Converts an interpolated string typed as `PathSegment`. The literal parts
	## and interpolated values are joined, then encoded as one segment.
	##
	## The literal parts must contain a character other than `.`; otherwise it is
	## a compile-time error. That character keeps the joined value from being
	## empty, `.`, or `..` whatever the interpolated values are, which matters
	## because a value computed at run time cannot be rejected here. Use
	## `from_str` for a segment that is entirely computed.
	from_interpolation : List(Str) -> Try((List(Str) -> PathSegment), [InvalidInterpolation(Str)])
	from_interpolation = |segments|
		if segments.any(|segment| Str.to_utf8(segment).any(|byte| byte != '.')) {
			Str.from_interpolation(segments).map_ok(|assemble| |values| PathSegment.({ encoded: PercentEncoding.encode(assemble(values)) }))
		} else {
			Err(InvalidInterpolation("an interpolated path segment needs a character other than . outside its interpolations; use PathSegment.from_str for a segment computed at run time"))
		}

	## Encodes a runtime string. Returns `Err(EmptySegment)` if it is empty and
	## `Err(DotSegment)` if it is exactly `.` or `..`.
	from_str : Str -> Try(PathSegment, [DotSegment, EmptySegment])
	from_str = |raw|
		if Str.is_empty(raw) {
			Err(EmptySegment)
		} else if raw == "." or raw == ".." {
			Err(DotSegment)
		} else {
			Ok(PathSegment.({ encoded: PercentEncoding.encode(raw) }))
		}

	## The encoded text.
	inner : PathSegment -> Str
	inner = |PathSegment.(value)| value.encoded
}

expect {
	segment : PathSegment
	segment = "AZaz09-._~"
	PathSegment.inner(segment) == "AZaz09-._~"
}

expect {
	segment : PathSegment
	segment = "a b/c?d"
	PathSegment.inner(segment) == "a%20b%2Fc%3Fd"
}

expect {
	value = "a/b 鵬"
	segment : PathSegment
	segment = "prefix-${value}-suffix"
	segment == PathSegment.({ encoded: "prefix-a%2Fb%20%E9%B5%AC-suffix" })
}

# Length boundaries: empty, one/two dots, and the first safe dot run.
expect PathSegment.from_str("") == Err(EmptySegment)
expect PathSegment.from_str("a") == Ok(PathSegment.({ encoded: "a" }))
expect PathSegment.from_str(".") == Err(DotSegment)
expect PathSegment.from_str("..") == Err(DotSegment)
expect PathSegment.from_str("...") == Ok(PathSegment.({ encoded: "..." }))
expect PathSegment.from_str("a.b") == Ok(PathSegment.({ encoded: "a.b" }))
expect PathSegment.from_str("%2e%2e") == Ok(PathSegment.({ encoded: "%252e%252e" }))

# The literal parts decide at compile time: only dots or nothing outside the
# interpolations is rejected, one other character is enough.
expect PathSegment.from_interpolation(["", ""]).is_err()
expect PathSegment.from_interpolation([".", ""]).is_err()
expect PathSegment.from_interpolation(["..", "."]).is_err()
expect PathSegment.from_interpolation(["a", ""]).is_ok()
expect PathSegment.from_interpolation(["", "-"]).is_ok()

# With such a character, interpolated dots or emptiness cannot make the
# segment empty, `.`, or `..`.
expect {
	dot = "."
	value : PathSegment
	value = "a${dot}"
	value == PathSegment.({ encoded: "a." })
}
expect {
	empty = ""
	value : PathSegment
	value = "-${empty}"
	value == PathSegment.({ encoded: "-" })
}
