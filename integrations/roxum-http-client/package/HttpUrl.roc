## Absolute `http` / `https` URLs: what a request needs to reach the server
## and what its request line names. No I/O.
HttpUrl := [].{
	Scheme : [Http, Https]

	## `host` is without brackets (an IPv6 address is `::1`); `authority` is
	## the `Host` header's value, with brackets and a non-default port;
	## `target` is the path and the query, starting with `/`.
	Parts : {
		scheme : HttpUrl.Scheme,
		host : Str,
		port : U16,
		authority : Str,
		target : Str,
	}

	## Reads an absolute URL. User information (`user:password@`) is refused,
	## since it would travel in plain sight; the fragment is dropped, since it
	## is not sent.
	parse : Str -> Try(HttpUrl.Parts, [InvalidUrl(Str)])
	parse = |text| {
		if !all_visible(text) {
			return Err(InvalidUrl("the URL contains spaces or control characters"))
		}
		(scheme, rest) = match (text.drop_prefix_caseless_ascii("https://"), text.drop_prefix_caseless_ascii("http://")) {
			(Ok(after), _) => (Https, after)
			(_, Ok(after)) => (Http, after)
			_ => return Err(InvalidUrl("only http:// and https:// URLs are supported"))
		}
		without_fragment = before_byte(rest, '#')
		bytes = without_fragment.to_utf8()
		authority_end = bytes.find_first_index(|byte| byte == '/' or byte == '?') ?? bytes.len()
		authority_text = Str.from_utf8_lossy(bytes.take_first(authority_end))
		path_and_query = Str.from_utf8_lossy(bytes.drop_first(authority_end))
		if authority_text.contains("@") {
			return Err(InvalidUrl("user information in a URL is not supported"))
		}
		(host, explicit_port) = split_host_port(authority_text)?
		port = match explicit_port {
			Ok(number) => number
			Err(Missing) => default_port(scheme)
		}
		target = if path_and_query.starts_with("/") {
			path_and_query
		} else {
			"/${path_and_query}"
		}
		Ok({ scheme, host, port, authority: authority_of(scheme, host, port), target: normalize_target(target) })
	}

	## The URL a redirect's `Location` names, read against the URL of the
	## request that got it: absolute, scheme-relative (`//host/path`),
	## absolute-path (`/path`), or relative to the base's directory.
	resolve : HttpUrl.Parts, Str -> Try(HttpUrl.Parts, [InvalidUrl(Str)])
	resolve = |base, location| {
		trimmed = location.trim()
		if starts_with_ignoring_case(trimmed, "http://") or starts_with_ignoring_case(trimmed, "https://") {
			return HttpUrl.parse(trimmed)
		}
		scheme_text = match base.scheme {
			Http => "http:"
			Https => "https:"
		}
		if trimmed.starts_with("//") {
			return HttpUrl.parse("${scheme_text}${trimmed}")
		}
		if !all_visible(trimmed) {
			return Err(InvalidUrl("the redirect location contains spaces or control characters"))
		}
		if trimmed.to_utf8().contains(':') and !trimmed.starts_with("/") and !(trimmed.starts_with("?")) {
			# Another scheme, such as `ftp:`, before any slash.
			first_colon = trimmed.to_utf8().find_first_index(|byte| byte == ':') ?? 0
			first_slash = trimmed.to_utf8().find_first_index(|byte| byte == '/') ?? trimmed.to_utf8().len()
			if first_colon < first_slash {
				return Err(InvalidUrl("only http:// and https:// URLs are supported"))
			}
		}
		relative = before_byte(trimmed, '#')
		target = if relative.starts_with("/") {
			relative
		} else if relative.starts_with("?") {
			"${before_byte(base.target, '?')}${relative}"
		} else if relative == "" {
			base.target
		} else {
			path = before_byte(base.target, '?')
			directory_end = (path.to_utf8().find_last_index(|byte| byte == '/') ?? 0) + 1
			"${Str.from_utf8_lossy(path.to_utf8().take_first(directory_end))}${relative}"
		}
		Ok({ ..base, target: normalize_target(target) })
	}

	## True when both name the same scheme, host, and port.
	same_origin : HttpUrl.Parts, HttpUrl.Parts -> Bool
	same_origin = |left, right|
		left.scheme == right.scheme and left.port == right.port and left.host.caseless_ascii_equals(right.host)

	to_str : HttpUrl.Parts -> Str
	to_str = |parts| {
		scheme_text = match parts.scheme {
			Http => "http"
			Https => "https"
		}
		"${scheme_text}://${parts.authority}${parts.target}"
	}
}

default_port : HttpUrl.Scheme -> U16
default_port = |scheme|
	match scheme {
		Http => 80
		Https => 443
	}

authority_of : HttpUrl.Scheme, Str, U16 -> Str
authority_of = |scheme, host, port| {
	shown_host = if host.contains(":") {
		"[${host}]"
	} else {
		host
	}
	if port == default_port(scheme) {
		shown_host
	} else {
		"${shown_host}:${port.to_str()}"
	}
}

split_host_port : Str -> Try((Str, Try(U16, [Missing])), [InvalidUrl(Str)])
split_host_port = |authority| {
	bytes = authority.to_utf8()
	(host, port_text) = if authority.starts_with("[") {
		close = bytes.find_first_index(|byte| byte == ']') ?? return Err(InvalidUrl("an IPv6 address without a closing bracket"))
		inside = Str.from_utf8_lossy(bytes.sublist({ start: 1, len: close - 1 }))
		after = bytes.drop_first(close + 1)
		if after.is_empty() {
			(inside, Err(Missing))
		} else if after.first() == Ok(':') {
			(inside, Ok(Str.from_utf8_lossy(after.drop_first(1))))
		} else {
			return Err(InvalidUrl("unexpected text after an IPv6 address"))
		}
	} else {
		match bytes.find_last_index(|byte| byte == ':') {
			Ok(colon) => (Str.from_utf8_lossy(bytes.take_first(colon)), Ok(Str.from_utf8_lossy(bytes.drop_first(colon + 1))))
			Err(_) => (authority, Err(Missing))
		}
	}
	if host == "" or !(host.to_utf8().all(host_byte)) {
		return Err(InvalidUrl("the URL has no valid host"))
	}
	port = match port_text {
		Ok("") => Err(Missing)
		Ok(text) =>
			match U16.from_str(text) {
				Ok(0) => return Err(InvalidUrl("port 0 is not valid"))
				Ok(number) => Ok(number)
				Err(_) => return Err(InvalidUrl("the port is not a number from 1 to 65535"))
			}
		Err(Missing) => Err(Missing)
	}
	Ok((host, port))
}

## Letters, digits, and what host names and IP addresses use. Percent
## escapes and international names are not supported.
host_byte : U8 -> Bool
host_byte = |byte|
	(byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '-' or byte == ':' or byte == '_'

all_visible : Str -> Bool
all_visible = |text| text.to_utf8().all(|byte| byte > 32 and byte != 127)

before_byte : Str, U8 -> Str
before_byte = |text, mark| {
	bytes = text.to_utf8()
	match bytes.find_first_index(|byte| byte == mark) {
		Ok(index) => Str.from_utf8_lossy(bytes.take_first(index))
		Err(_) => text
	}
}

starts_with_ignoring_case : Str, Str -> Bool
starts_with_ignoring_case = |text, prefix| text.drop_prefix_caseless_ascii(prefix).is_ok()

expect {
	parts = HttpUrl.parse("https://API.example.com/v1/rates?country=JP#top")
	parts == Ok({ scheme: Https, host: "API.example.com", port: 443, authority: "API.example.com", target: "/v1/rates?country=JP" })
}

expect HttpUrl.parse("http://127.0.0.1:8080").map_ok(|parts| (parts.port, parts.authority, parts.target)) == Ok((8080, "127.0.0.1:8080", "/"))
expect HttpUrl.parse("http://[::1]:9000/x").map_ok(|parts| (parts.host, parts.authority)) == Ok(("::1", "[::1]:9000"))
expect HttpUrl.parse("http://example.com?q=1").map_ok(|parts| parts.target) == Ok("/?q=1")
expect HttpUrl.parse("https://example.com:443/").map_ok(|parts| parts.authority) == Ok("example.com")
expect HttpUrl.parse("ftp://example.com/").is_err()
expect HttpUrl.parse("https://user:secret@example.com/").is_err()
expect HttpUrl.parse("https://example.com/a b").is_err()
expect HttpUrl.parse("https://example.com:0/").is_err()
expect HttpUrl.parse("https://example.com:65536/").is_err()
expect HttpUrl.parse("https:///path").is_err()

expect {
	base = HttpUrl.parse("https://example.com/v1/rates?country=JP") ?? crash "base"
	resolved = ["/other", "next", "?page=2", "https://other.example/x", "//cdn.example/y"].map(|location| HttpUrl.resolve(base, location).map_ok(HttpUrl.to_str))
	resolved == [Ok("https://example.com/other"), Ok("https://example.com/v1/next"), Ok("https://example.com/v1/rates?page=2"), Ok("https://other.example/x"), Ok("https://cdn.example/y")]
}

expect {
	base = HttpUrl.parse("https://example.com/") ?? crash "base"
	HttpUrl.resolve(base, "ftp://example.com/").is_err() and HttpUrl.resolve(base, "mailto:x@example.com").is_err()
}

expect {
	a = HttpUrl.parse("https://Example.com/a") ?? crash "a"
	b = HttpUrl.parse("https://example.com:443/b") ?? crash "b"
	c = HttpUrl.parse("http://example.com/a") ?? crash "c"
	HttpUrl.same_origin(a, b) and !HttpUrl.same_origin(a, c)
}

# Remove literal dot segments only from the path; preserve the query and
# percent-encoded segments. Empty segments preserve repeated slashes.
normalize_target : Str -> Str
normalize_target = |target| {
	path = before_byte(target, '?')
	query = Str.from_utf8_lossy(target.to_utf8().drop_first(path.to_utf8().len()))
	var $segments = []
	for segment in path.split_on("/").drop_first(1) {
		if segment == ".." {
			$segments = $segments.drop_last(1)
		} else if segment != "." {
			$segments = $segments.append(segment)
		}
	}
	trailing = path.ends_with("/.") or path.ends_with("/..")
	normalized = "/${Str.join_with($segments, "/")}"
	suffix = if trailing and !$segments.is_empty() {
		"/"
	} else {
		""
	}
	"${normalized}${suffix}${query}"
}

# Parent traversal, current directory, and query isolation.
expect normalize_target("/a/../c") == "/c"
expect normalize_target("/a/./b?x=../c") == "/a/b?x=../c"
# Parent traversal at the root boundary and beyond it.
expect normalize_target("/a/..") == "/"
expect normalize_target("/a/b/..") == "/a/"
expect normalize_target("/../../c") == "/c"
# Empty and encoded segments must not be treated as dot segments.
expect normalize_target("/a//b") == "/a//b"
expect normalize_target("/%2e%2e/c") == "/%2e%2e/c"

# Relative and absolute redirect paths use the same normalization.
expect {
	base = HttpUrl.parse("http://example.com/a/b") ?? crash "base"
	HttpUrl.resolve(base, "../c") == HttpUrl.parse("http://example.com/c")
		and HttpUrl.resolve(base, "/a/../c") == HttpUrl.parse("http://example.com/c")
}

# A final dot removes only itself, preserving preceding empty segments.
expect normalize_target("/a//.") == "/a//"
expect normalize_target("/a///..") == "/a//"
