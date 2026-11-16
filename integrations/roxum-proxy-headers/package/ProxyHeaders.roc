import pf.HeaderName
import pf.Instant
import pf.IpAddr
import pf.Reply
import pf.Request
import pf.RequestHead
import pf.RemoteAddr
import pf.RequestHeader

ProxyHeaders := [].{

	## Uses `X-Forwarded-For` to recover the client address when the direct peer
	## is a trusted proxy. `trusted` holds addresses or CIDR ranges such as
	## "10.0.0.0/16" or "::1"; a `/0` range, which would trust every peer, is
	## rejected. From any other peer every forwarding field (`X-Forwarded-*`,
	## `X-Real-IP`, `Forwarded`) is removed, so handlers never see a
	## client-supplied value. From a trusted peer the resolved `X-Forwarded-For`
	## is removed too; read the address from `remote_addr`. Pass it to
	## `Router.before_routing` so every request sees the same address, whatever
	## route or fallback answers it.
	try_trust : List(Str) -> Try((model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply)), [InvalidProxy(Str)])
	try_trust = |trusted|
		match parse_all(trusted) {
			Ok(ranges) => Ok(|_model, head| Ok(ProxyHeaders.resolve(ranges, head)))
			Err(error) => Err(error)
		}

	trust : List(Str) -> (model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply))
	trust = |trusted|
		match ProxyHeaders.try_trust(trusted) {
			Ok(check!) => check!
			Err(InvalidProxy(entry)) => crash "roxum-proxy-headers: not an address or CIDR range: ${entry}"
		}

	## Explicitly trusts Unix peers. Restrict access to the socket directory;
	## this grants every process that can connect permission to supply forwarding
	## headers. `trusted` describes any earlier TCP proxies in the chain.
	try_trust_unix : List(Str) -> Try((model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply)), [InvalidProxy(Str)])
	try_trust_unix = |trusted|
		match parse_all(trusted) {
			Ok(ranges) => Ok(|_model, head| Ok(resolve_peer(ranges, Bool.True, head)))
			Err(error) => Err(error)
		}

	trust_unix : List(Str) -> (model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply))
	trust_unix = |trusted|
		match ProxyHeaders.try_trust_unix(trusted) {
			Ok(check!) => check!
			Err(InvalidProxy(entry)) => crash "roxum-proxy-headers: not an address or CIDR range: ${entry}"
		}

	## The scheme the client used, from the nearest proxy's `X-Forwarded-Proto`.
	## Only meaningful after `trust` ran: from an untrusted peer the field has
	## been removed and the result is `Http`.
	scheme : Request -> [Http, Https]
	scheme = |request| {
		values = List.join(List.map(field_values(request.headers, proto_name), split_list))
		match List.last(values) {
			Ok(value) if ascii_lower(value) == "https".to_utf8() => Https
			_ => Http
		}
	}

	## Applies the trust decision to one request's metadata.
	resolve : List({ network : IpAddr, prefix : U8 }), RequestHead(tag, provided) -> RequestHead
	resolve = |ranges, request| resolve_peer(ranges, Bool.False, request)
}

resolve_peer : List({ network : IpAddr, prefix : U8 }), Bool, RequestHead(tag, provided) -> RequestHead
resolve_peer = |ranges, trust_unix, request|
	if !(
		match request.remote_addr {
			Tcp({ ip, .. }) => trusted_ip(ranges, ip)
			Unix => trust_unix
		}
	) {
		without_forwarded(request)
	} else {
		entries = List.join(List.map(field_values(request.headers, for_name), split_list))
		if List.is_empty(entries) {
			request
		} else {
			match client_address(ranges, entries) {
				Ok(ip) => {
					..request,
					remote_addr: RemoteAddr.Tcp({ ip, port: 0 }),
					# The chain may start with values the client wrote; the
					# resolved address is the only part to trust.
					headers: List.drop_if(request.headers, |header| header.name == for_name),
				}
				Err(InvalidEntry) => without_forwarded(request)
			}
		}
	}

for_name : HeaderName
for_name = HeaderName.("x-forwarded-for")

proto_name : HeaderName
proto_name = HeaderName.("x-forwarded-proto")

without_forwarded : RequestHead(tag, provided) -> RequestHead
without_forwarded = |request|
	{ ..request, headers: List.drop_if(request.headers, |header| is_forwarding_name(header.name)) }

# Fields a proxy uses to describe the client. Names are lowercase on received
# requests.
is_forwarding_name : HeaderName -> Bool
is_forwarding_name = |name| {
	text = HeaderName.inner(name)
	Str.starts_with(text, "x-forwarded-") or text == "x-real-ip" or text == "forwarded"
}

field_values : List(RequestHeader), HeaderName -> List(List(U8))
field_values = |headers, name|
	List.map(List.keep_if(headers, |header| header.name == name), |header| header.value)

# Splits a comma-separated field into trimmed, non-empty entries.
split_list : List(U8) -> List(List(U8))
split_list = |bytes|
	List.keep_if(List.map(List.split_on(bytes, ','), trim_bytes), |entry| !List.is_empty(entry))

trim_bytes : List(U8) -> List(U8)
trim_bytes = |bytes| {
	var $start = 0
	var $end = List.len(bytes)
	while $start < $end and is_space(List.get(bytes, $start) ?? 'x') {
		$start = $start + 1
	}
	while $end > $start and is_space(List.get(bytes, $end - 1) ?? 'x') {
		$end = $end - 1
	}
	List.sublist(bytes, { start: $start, len: $end - $start })
}

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\t'

ascii_lower : List(U8) -> List(U8)
ascii_lower = |bytes| List.map(
	bytes,
	|byte| if byte >= 'A' and byte <= 'Z' {
		byte + 32
	} else {
		byte
	},
)

# Walks the chain from the nearest hop. Trusted proxies are skipped; the first
# untrusted address is the client. When every hop is trusted, the farthest one
# is used.
client_address : List({ network : IpAddr, prefix : U8 }), List(List(U8)) -> Try(IpAddr, [InvalidEntry])
client_address = |ranges, entries| {
	var $index = List.len(entries)
	var $last = Err(InvalidEntry)
	while $index > 0 {
		$index = $index - 1
		match parse_host(List.get(entries, $index) ?? []) {
			Ok(ip) => {
				if !trusted_ip(ranges, ip) {
					return Ok(ip)
				}
				$last = Ok(ip)
			}
			Err(_) => return Err(InvalidEntry)
		}
	}
	$last
}

trusted_ip : List({ network : IpAddr, prefix : U8 }), IpAddr -> Bool
trusted_ip = |ranges, ip| List.any(ranges, |range| contains(range, ip))

parse_all : List(Str) -> Try(List({ network : IpAddr, prefix : U8 }), [InvalidProxy(Str)])
parse_all = |entries| {
	var $ranges = []
	for entry in entries {
		match parse_range(entry) {
			Ok(range) => {
				$ranges = List.append($ranges, range)
			}
			Err(_) => return Err(InvalidProxy(entry))
		}
	}
	Ok($ranges)
}

# Parses "address" or "address/prefix". A bare address is a full-length range.
parse_range : Str -> Try({ network : IpAddr, prefix : U8 }, [InvalidRange])
parse_range = |text| {
	parts = Str.split_on(text, "/")
	address = match parse_ip((List.first(parts) ?? "").to_utf8()) {
		Ok(ip) => ip
		Err(_) => return Err(InvalidRange)
	}
	width : U64
	width = match address {
		V4(_) => 32
		V6(_) => 128
	}
	prefix = match parts {
		[_] => width
		[_, digits] =>
			match parse_decimal(digits.to_utf8(), width) {
				# A zero-length prefix trusts every address, clients included.
				Ok(0) => return Err(InvalidRange)
				Ok(value) => value
				Err(_) => return Err(InvalidRange)
			}
		_ => return Err(InvalidRange)
	}
	Ok({ network: address, prefix: U64.to_u8_wrap(prefix) })
}

# An address in a forwarded chain: a plain address, "[v6]", "[v6]:port", or
# "v4:port".
parse_host : List(U8) -> Try(IpAddr, [InvalidAddress])
parse_host = |bytes|
	if List.first(bytes) == Ok('[') {
		match List.find_first_index(bytes, |byte| byte == ']') {
			Ok(close) => {
				rest = List.drop_first(bytes, close + 1)
				if List.is_empty(rest) or (List.first(rest) == Ok(':') and is_port(List.drop_first(rest, 1))) {
					match parse_ipv6(List.sublist(bytes, { start: 1, len: close - 1 })) {
						Ok(groups) => Ok(V6(groups))
						Err(_) => Err(InvalidAddress)
					}
				} else {
					Err(InvalidAddress)
				}
			}
			Err(_) => Err(InvalidAddress)
		}
	} else if List.count_if(bytes, |byte| byte == ':') == 1 {
		parts = List.split_on(bytes, ':')
		if is_port(List.last(parts) ?? []) {
			match parse_ipv4(List.first(parts) ?? []) {
				Ok(octets) => Ok(V4(octets))
				Err(_) => Err(InvalidAddress)
			}
		} else {
			Err(InvalidAddress)
		}
	} else {
		match parse_ip(bytes) {
			Ok(ip) => Ok(ip)
			Err(_) => Err(InvalidAddress)
		}
	}

is_port : List(U8) -> Bool
is_port = |bytes| parse_decimal(bytes, 65_535).is_ok()

parse_ip : List(U8) -> Try(IpAddr, [InvalidAddress])
parse_ip = |bytes|
	if List.contains(bytes, ':') {
		match parse_ipv6(bytes) {
			Ok(groups) => Ok(V6(groups))
			Err(_) => Err(InvalidAddress)
		}
	} else {
		match parse_ipv4(bytes) {
			Ok(octets) => Ok(V4(octets))
			Err(_) => Err(InvalidAddress)
		}
	}

# Decimal without sign or leading zeros, at most `maximum`.
parse_decimal : List(U8), U64 -> Try(U64, [InvalidNumber])
parse_decimal = |bytes, maximum| {
	if List.is_empty(bytes) or List.len(bytes) > 5 or (List.len(bytes) > 1 and List.first(bytes) == Ok('0')) {
		return Err(InvalidNumber)
	}
	var $value = 0
	for byte in bytes {
		if byte < '0' or byte > '9' {
			return Err(InvalidNumber)
		}
		$value = $value * 10 + U8.to_u64(byte - '0')
	}
	if $value > maximum {
		Err(InvalidNumber)
	} else {
		Ok($value)
	}
}

parse_ipv4 : List(U8) -> Try((U8, U8, U8, U8), [InvalidAddress])
parse_ipv4 = |bytes| {
	var $octets = []
	for part in List.split_on(bytes, '.') {
		match parse_decimal(part, 255) {
			Ok(value) => {
				$octets = List.append($octets, U64.to_u8_wrap(value))
			}
			Err(_) => return Err(InvalidAddress)
		}
	}
	match $octets {
		[a, b, c, d] => Ok((a, b, c, d))
		_ => Err(InvalidAddress)
	}
}

parse_hex_group : List(U8) -> Try(U16, [InvalidAddress])
parse_hex_group = |bytes| {
	if List.is_empty(bytes) or List.len(bytes) > 4 {
		return Err(InvalidAddress)
	}
	var $value = 0
	for byte in bytes {
		digit = if byte >= '0' and byte <= '9' {
			byte - '0'
		} else if byte >= 'a' and byte <= 'f' {
			byte - 'a' + 10
		} else if byte >= 'A' and byte <= 'F' {
			byte - 'A' + 10
		} else {
			return Err(InvalidAddress)
		}
		$value = $value * 16 + U8.to_u16(digit)
	}
	Ok($value)
}

# Groups of one side of "::". The last group may be a dotted IPv4 address,
# which fills two groups.
parse_groups : List(U8), Bool -> Try(List(U16), [InvalidAddress])
parse_groups = |bytes, allow_ipv4| {
	if List.is_empty(bytes) {
		return Ok([])
	}
	parts = List.split_on(bytes, ':')
	count = List.len(parts)
	var $groups = []
	var $index = 0
	for part in parts {
		$index = $index + 1
		if $index == count and allow_ipv4 and List.contains(part, '.') {
			match parse_ipv4(part) {
				Ok((a, b, c, d)) => {
					$groups = List.concat($groups, [U8.to_u16(a) * 256 + U8.to_u16(b), U8.to_u16(c) * 256 + U8.to_u16(d)])
				}
				Err(_) => return Err(InvalidAddress)
			}
		} else {
			match parse_hex_group(part) {
				Ok(group) => {
					$groups = List.append($groups, group)
				}
				Err(_) => return Err(InvalidAddress)
			}
		}
	}
	Ok($groups)
}

parse_ipv6 : List(U8) -> Try((U16, U16, U16, U16, U16, U16, U16, U16), [InvalidAddress])
parse_ipv6 = |bytes| {
	halves = Str.split_on(Str.from_utf8_lossy(bytes), "::")
	groups = match halves {
		[whole] => parse_groups(whole.to_utf8(), Bool.True)?
		[head, tail] => {
			front = parse_groups(head.to_utf8(), Bool.False)?
			back = parse_groups(tail.to_utf8(), Bool.True)?
			used = List.len(front) + List.len(back)
			if used > 7 {
				return Err(InvalidAddress)
			}
			List.concat(List.concat(front, List.repeat(0, 8 - used)), back)
		}
		_ => return Err(InvalidAddress)
	}
	match groups {
		[a, b, c, d, e, f, g, h] => Ok((a, b, c, d, e, f, g, h))
		_ => Err(InvalidAddress)
	}
}

contains : { network : IpAddr, prefix : U8 }, IpAddr -> Bool
contains = |range, ip|
	match (range.network, ip) {
		(V4(network), V4(address)) => {
			mask = if range.prefix == 0 {
				0
			} else {
				U32.shl_wrap(0xFFFF_FFFF, 32 - range.prefix)
			}
			U32.bitwise_and(ipv4_value(network), mask) == U32.bitwise_and(ipv4_value(address), mask)
		}
		(V6(network), V6(address)) => {
			network_groups = ipv6_list(network)
			address_groups = ipv6_list(address)
			List.all(
				[0, 1, 2, 3, 4, 5, 6, 7],
				|index| {
					covered = U8.min(16, U8.minus_saturated(range.prefix, U64.to_u8_wrap(index) * 16))
					mask = if covered == 0 {
						0
					} else {
						U16.shl_wrap(0xFFFF, 16 - covered)
					}
					U16.bitwise_and(List.get(network_groups, index) ?? 0, mask) == U16.bitwise_and(List.get(address_groups, index) ?? 0, mask)
				},
			)
		}
		_ => Bool.False
	}

ipv4_value : (U8, U8, U8, U8) -> U32
ipv4_value = |(a, b, c, d)|
	U8.to_u32(a) * 16_777_216 + U8.to_u32(b) * 65_536 + U8.to_u32(c) * 256 + U8.to_u32(d)

ipv6_list : (U16, U16, U16, U16, U16, U16, U16, U16) -> List(U16)
ipv6_list = |(a, b, c, d, e, f, g, h)| [a, b, c, d, e, f, g, h]

ip4 = |a, b, c, d| V4((a, b, c, d))

range = |text|
	match parse_range(text) {
		Ok(value) => value
		Err(_) => crash "invalid test range"
	}

trusted_ranges = |{}| [range("10.0.0.0/8"), range("127.0.0.1")]

bytes = |text| text.to_utf8()

request_from = |remote, headers|
	RequestHead.from_request(request_with(remote, headers), Instant.from_nanoseconds(0), {})

request_with = |remote, headers|
	Request.{
		method: GET,
		version: Http11,
		raw_target: "/".to_utf8(),
		path: "/",
		query: [],
		headers,
		body: Empty,
		remote_addr: RemoteAddr.Tcp({ ip: remote, port: 5000 }),
		request_id: "test",
	}

header = |name, value| RequestHeader.{ name: HeaderName.(name), value: value.to_utf8() }

# IPv4 octet boundaries and shape.
expect parse_ipv4(bytes("0.0.0.0")) == Ok((0, 0, 0, 0))
expect parse_ipv4(bytes("255.255.255.255")) == Ok((255, 255, 255, 255))
expect parse_ipv4(bytes("256.0.0.0")).is_err()
expect parse_ipv4(bytes("01.2.3.4")).is_err()
expect parse_ipv4(bytes("1.2.3")).is_err()
expect parse_ipv4(bytes("1.2.3.4.5")).is_err()
expect parse_ipv4(bytes("")).is_err()

# IPv6 compression, embedded IPv4, and group count limits.
expect parse_ipv6(bytes("::")) == Ok((0, 0, 0, 0, 0, 0, 0, 0))
expect parse_ipv6(bytes("::1")) == Ok((0, 0, 0, 0, 0, 0, 0, 1))
expect parse_ipv6(bytes("2001:db8::1")) == Ok((0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
expect parse_ipv6(bytes("1:2:3:4:5:6:7:8")) == Ok((1, 2, 3, 4, 5, 6, 7, 8))
expect parse_ipv6(bytes("::ffff:192.0.2.1")) == Ok((0, 0, 0, 0, 0, 0xffff, 0xc000, 0x0201))
expect parse_ipv6(bytes("1:2:3:4:5:6:7:8:9")).is_err()
expect parse_ipv6(bytes("1:2:3:4:5:6:7::8")).is_err()
expect parse_ipv6(bytes("1::2::3")).is_err()
expect parse_ipv6(bytes("12345::")).is_err()
expect parse_ipv6(bytes("g::")).is_err()

# CIDR prefix boundaries per family.
expect parse_range("10.0.0.0/0").is_err()
expect parse_range("10.0.0.0/1").is_ok()
expect parse_range("10.0.0.0/32").is_ok()
expect parse_range("10.0.0.0/33").is_err()
expect parse_range("10.0.0.0/08").is_err()
expect parse_range("::/0").is_err()
expect parse_range("::/1").is_ok()
expect parse_range("::/128").is_ok()
expect parse_range("::/129").is_err()
expect parse_range("1.2.3.4/8/9").is_err()
expect parse_range("proxy.internal").is_err()

# Range membership around the prefix edge.
expect contains(range("10.0.0.0/8"), ip4(10, 255, 255, 255))
expect !contains(range("10.0.0.0/8"), ip4(11, 0, 0, 0))
expect contains(range("0.0.0.0/1"), ip4(127, 255, 255, 255))
expect !contains(range("0.0.0.0/1"), ip4(128, 0, 0, 0))
expect contains(range("127.0.0.1"), ip4(127, 0, 0, 1))
expect !contains(range("127.0.0.1"), ip4(127, 0, 0, 2))
expect contains(range("2001:db8::/32"), V6((0x2001, 0xdb8, 0xffff, 0, 0, 0, 0, 1)))
expect !contains(range("2001:db8::/32"), V6((0x2001, 0xdb9, 0, 0, 0, 0, 0, 0)))
expect contains(range("::/127"), V6((0, 0, 0, 0, 0, 0, 0, 1)))
expect !contains(range("::/127"), V6((0, 0, 0, 0, 0, 0, 0, 2)))
expect !contains(range("::/1"), ip4(1, 2, 3, 4))

# Forwarded entries may carry ports.
expect parse_host(bytes("[::1]:443")) == Ok(V6((0, 0, 0, 0, 0, 0, 0, 1)))
expect parse_host(bytes("[::1]")) == Ok(V6((0, 0, 0, 0, 0, 0, 0, 1)))
expect parse_host(bytes("192.0.2.1:65535")) == Ok(ip4(192, 0, 2, 1))
expect parse_host(bytes("192.0.2.1:65536")).is_err()
expect parse_host(bytes("[::1]x")).is_err()

# The client is the nearest untrusted hop; values a client prepends are ignored.
expect client_address(trusted_ranges({}), [bytes("203.0.113.9")]) == Ok(ip4(203, 0, 113, 9))
expect client_address(trusted_ranges({}), [bytes("198.51.100.1"), bytes("10.0.0.5")]) == Ok(ip4(198, 51, 100, 1))
expect client_address(trusted_ranges({}), [bytes("198.51.100.1"), bytes("203.0.113.9")]) == Ok(ip4(203, 0, 113, 9))
expect client_address(trusted_ranges({}), [bytes("10.0.0.1"), bytes("10.0.0.2")]) == Ok(ip4(10, 0, 0, 1))
expect client_address(trusted_ranges({}), [bytes("not-an-ip"), bytes("10.0.0.2")]) == Err(InvalidEntry)

expect split_list(bytes(" 198.51.100.1 ,, 10.0.0.5 ")) == [bytes("198.51.100.1"), bytes("10.0.0.5")]

# Untrusted peer: every forwarding field is removed and the address stays.
expect {
	forwarding = [
		header("x-forwarded-for", "203.0.113.9"),
		header("x-forwarded-proto", "https"),
		header("x-forwarded-host", "evil.example"),
		header("x-forwarded-port", "443"),
		header("x-real-ip", "203.0.113.9"),
		header("forwarded", "for=203.0.113.9"),
	]
	request = ProxyHeaders.resolve(trusted_ranges({}), request_from(ip4(192, 0, 2, 7), List.append(forwarding, header("host", "x"))))
	request.remote_addr == RemoteAddr.Tcp({ ip: ip4(192, 0, 2, 7), port: 5000 }) and request.headers == [header("host", "x")]
}

# Names that only resemble forwarding fields are kept.
expect !is_forwarding_name(HeaderName.("x-forwarded"))
expect !is_forwarding_name(HeaderName.("forwarded-for"))
expect is_forwarding_name(HeaderName.("x-forwarded-"))

# Trusted peer: the client address replaces the peer, the port is unknown, and
# the raw chain is removed; the proxy's protocol field stays for `scheme`.
expect {
	request = ProxyHeaders.resolve(trusted_ranges({}), request_from(ip4(10, 0, 0, 5), [header("x-forwarded-for", "198.51.100.1"), header("x-forwarded-for", "10.0.0.9"), header("x-forwarded-proto", "https")]))
	request.remote_addr == RemoteAddr.Tcp({ ip: ip4(198, 51, 100, 1), port: 0 }) and request.headers == [header("x-forwarded-proto", "https")]
}

# Trusted peer without forwarded fields: unchanged.
expect {
	request = ProxyHeaders.resolve(trusted_ranges({}), request_from(ip4(10, 0, 0, 5), [header("host", "x")]))
	request.remote_addr == RemoteAddr.Tcp({ ip: ip4(10, 0, 0, 5), port: 5000 }) and request.headers == [header("host", "x")]
}

# Trusted peer with an unparsable chain: the peer address stays and the fields go.
expect {
	request = ProxyHeaders.resolve(trusted_ranges({}), request_from(ip4(10, 0, 0, 5), [header("x-forwarded-for", "unknown")]))
	request.remote_addr == RemoteAddr.Tcp({ ip: ip4(10, 0, 0, 5), port: 5000 }) and List.is_empty(request.headers)
}

expect ProxyHeaders.scheme(request_with(ip4(10, 0, 0, 5), [header("x-forwarded-proto", "https")])) == Https
expect ProxyHeaders.scheme(request_with(ip4(10, 0, 0, 5), [header("x-forwarded-proto", "HTTPS")])) == Https
expect ProxyHeaders.scheme(request_with(ip4(10, 0, 0, 5), [header("x-forwarded-proto", "http, https")])) == Https
expect ProxyHeaders.scheme(request_with(ip4(10, 0, 0, 5), [header("x-forwarded-proto", "http")])) == Http
expect ProxyHeaders.scheme(request_with(ip4(10, 0, 0, 5), [])) == Http

expect ProxyHeaders.try_trust(["10.0.0.0/8", "::1"]).is_ok()
expect
	match ProxyHeaders.try_trust(["10.0.0.0/8", "10.0.0.0/33"]) {
		Err(InvalidProxy("10.0.0.0/33")) => Bool.True
		_ => Bool.False
	}

# Unix connections carry no IP and are not trusted by CIDR policy.
expect {
	request = { ..request_from(ip4(127, 0, 0, 1), [header("x-forwarded-for", "192.0.2.1")]), remote_addr: RemoteAddr.Unix }
	resolved = ProxyHeaders.resolve(trusted_ranges({}), request)
	resolved.remote_addr == RemoteAddr.Unix and resolved.headers.is_empty()
}

expect {
	request = { ..request_from(ip4(127, 0, 0, 1), [header("x-forwarded-for", "192.0.2.1")]), remote_addr: RemoteAddr.Unix }
	resolved = resolve_peer([], Bool.True, request)
	resolved.remote_addr == RemoteAddr.Tcp({ ip: ip4(192, 0, 2, 1), port: 0 }) and resolved.headers.is_empty()
}
