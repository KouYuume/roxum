import pf.HeaderName
import pf.HeaderValue
import pf.Extract
import pf.Reply
import pf.RequestHeader
import pf.ResponseHeader
import pf.Secret
import pf.UrlEncoded

## A cookie to send: its name and value, and attributes that default to the safe
## choice. Sent with `Cookie.add`.
##
## ```roc
## reply = Reply.text("hello") |> Cookie.add(Cookie.{ name: "theme", value: "dark" })
## ```
##
## The value may be any text: what a cookie cannot hold is percent-encoded here
## and decoded when read.
Cookie := {
	name : Str,
	value : Str,
	path : Str ?? "/",
	domain : Cookie.Domain ?? Cookie.Domain.HostOnly,
	max_age : Cookie.MaxAge ?? Cookie.MaxAge.Session,
	same_site : Cookie.SameSite ?? Cookie.SameSite.Lax,

	## Browsers send a `Secure` cookie only over HTTPS; most also treat `localhost`
	## as secure. Turn it off only to serve plain HTTP.
	secure : Bool ?? Bool.True,

	## Scripts in the page cannot read an `HttpOnly` cookie.
	http_only : Bool ?? Bool.True,
}.{

	## `HostOnly` sends the cookie to the host that set it and no other.
	Domain := [HostOnly, Of(Str)]

	## `Session` lasts until the browser closes.
	MaxAge := [Session, Seconds(U64)]

	## `None` requires `secure`.
	SameSite := [Strict, Lax, None]

	## What `Cookie.remove` needs to name a cookie: the `path` and `domain` it was
	## set with.
	Removal := {
		name : Str,
		path : Str ?? "/",
		domain : Cookie.Domain ?? Cookie.Domain.HostOnly,
	}

	## The keys for signed cookies. New cookies are signed with `current`; cookies
	## signed with a key in `previous` are still accepted, so a key can be replaced
	## without signing every client out.
	Keys := { current : Secret, previous : List(Secret) ?? [] }

	## A `Handler.typed` field that reads the `Cookie` header into a record, as
	## `Cookie.parse` does. Answers 400 when it does not fit.
	##
	## ```roc
	## show! : Model, { cookies : Cookie.Read({ theme : Try(Str, [Missing]) }) } => Try(Reply, Reply)
	## show! = |_model, { cookies: Cookie.Read.(cookies) }| ...
	## ```
	Read(value) := value.{
		parser_for : Extract.Parser(Cookie.Read(value), provided) where [value.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Cookie.parse(context.request.headers) {
					Ok(value) => Ok(Cookie.Read.(value))
					Err(_) => Err(Reply.status(400))
				},
		)
	}

	## Appends a `Set-Cookie` field to the reply. Fails when the name is not an HTTP
	## token, the path or domain could not be sent, the name and value together pass
	## the 4096 bytes browsers hold, or browsers would refuse the attributes:
	## `SameSite=None` needs `secure`, the name prefix `__Secure-` needs `secure`, and
	## `__Host-` also needs the path `/` and `HostOnly`.
	add : Reply, Cookie -> Try(Reply, [InvalidName, InvalidPath, InvalidDomain, TooLarge, RefusedByBrowsers])
	add = |reply, cookie| {
		if !is_token(cookie.name) {
			return Err(InvalidName)
		}
		encoded = percent_encode(cookie.value, is_cookie_octet)
		if cookie.name.to_utf8().len() + encoded.to_utf8().len() > 4096 {
			return Err(TooLarge)
		}
		location = location_attributes(cookie.path, cookie.domain)?
		if refused_by_browsers(cookie) {
			return Err(RefusedByBrowsers)
		}
		max_age = match cookie.max_age {
			Session => ""
			Seconds(seconds) => "; Max-Age=${seconds.to_str()}"
		}
		same_site = match cookie.same_site {
			Strict => "; SameSite=Strict"
			Lax => "; SameSite=Lax"
			None => "; SameSite=None"
		}
		secure = if cookie.secure {
			"; Secure"
		} else {
			""
		}
		http_only = if cookie.http_only {
			"; HttpOnly"
		} else {
			""
		}
		Ok(with_set_cookie(reply, "${cookie.name}=${encoded}${location}${max_age}${same_site}${secure}${http_only}"))
	}

	## Appends a `Set-Cookie` field that makes the browser drop the cookie.
	remove : Reply, Cookie.Removal -> Try(Reply, [InvalidName, InvalidPath, InvalidDomain])
	remove = |reply, removal| {
		if !is_token(removal.name) {
			return Err(InvalidName)
		}
		location = location_attributes(removal.path, removal.domain)?
		# A prefixed name is only accepted with `Secure`. Other names go without it,
		# so that the removal also works over plain HTTP.
		secure = if removal.name.starts_with("__Secure-") or removal.name.starts_with("__Host-") {
			"; Secure"
		} else {
			""
		}
		Ok(with_set_cookie(reply, "${removal.name}=${location}; Max-Age=0${secure}"))
	}

	## The cookies in the request's `Cookie` fields, in order. A name is compared
	## exactly. A pair without `=`, or a value that is not UTF-8 once decoded, is
	## left out.
	all : List(RequestHeader) -> List({ name : Str, value : Str })
	all = |headers| {
		var $cookies = []
		for field in headers {
			if HeaderName.inner(field.name).with_ascii_lowercased() == "cookie" {
				$cookies = $cookies.concat(pairs_of(field.value))
			}
		}
		$cookies
	}

	## The value of the first cookie with this name. Browsers send the cookie with
	## the longest path first.
	get : List(RequestHeader), Str -> Try(Str, [NotFound])
	get = |headers, name|
		match List.find_first(Cookie.all(headers), |cookie| cookie.name == name) {
			Ok(found) => Ok(found.value)
			Err(_) => Err(NotFound)
		}

	## Reads the cookies into a record, chosen by the caller's type. Its fields are
	## `Str`, numbers, `Bool`, or `Try(_, [Missing])` for a cookie that may be left
	## out. A cookie the record does not have is ignored; of a name that repeats,
	## the first counts.
	parse : List(RequestHeader) -> Try(a, [TooManyBytes, TooManyFields, BadValue, ..errs])
		where [a.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, ..errs])]
	parse = |headers| {
		# Each loop updates one variable: with two, `--opt=speed` and `--opt=size`
		# miscompile the typed read (roc-lang/roc#12884).
		var $first = []
		for cookie in Cookie.all(headers) {
			if !$first.any(|kept| kept.name == cookie.name) {
				$first = $first.append(cookie)
			}
		}
		firsts = $first
		var $query = []
		for cookie in firsts {
			$query = $query.concat(percent_bytes(cookie.name, is_unreserved)).append('=').concat(percent_bytes(cookie.value, is_unreserved)).append('&')
		}
		query = $query
		UrlEncoded.parse(query, { max_bytes: query.len(), max_fields: firsts.len() })
	}

	## The cookie with its value signed: `Cookie.verified!` gives the value back only
	## if this app, or one with the same keys, signed it for this name. The value
	## stays readable by the client. A signature does not expire, so a value that
	## should end holds its own time.
	sign! : Cookie, Cookie.Keys => Try(Cookie, [SigningFailed])
	sign! = |cookie, keys| {
		signature = signature_with!(keys.current, cookie.name, cookie.value)?
		Ok({ ..cookie, value: "${signature}.${cookie.value}" })
	}

	## The value of the cookie with this name whose signature is good, under any of
	## the keys. Signatures are compared in time that does not depend on where they
	## differ.
	verified! : List(RequestHeader), Cookie.Keys, Str => Try(Str, [NotFound, BadSignature, SigningFailed])
	verified! = |headers, keys, name| {
		var $found = Bool.False
		for cookie in Cookie.all(headers) {
			if cookie.name == name {
				$found = Bool.True
				bytes = cookie.value.to_utf8()
				if bytes.get(signature_length) == Ok('.') {
					value = Str.from_utf8(bytes.drop_first(signature_length + 1)) ?? ""
					sent = bytes.take_first(signature_length)
					for key in List.prepend(keys.previous, keys.current) {
						expected = signature_with!(key, name, value)?
						if same_bytes(sent, expected.to_utf8()) {
							return Ok(value)
						}
					}
				}
			}
		}
		if $found {
			Err(BadSignature)
		} else {
			Err(NotFound)
		}
	}
}

# Hex of an HMAC-SHA-256.
signature_length : U64
signature_length = 64

# The name is signed too, so that a signature cannot be moved to another cookie.
# The prefix keeps these signatures apart from other uses of the same key. A name
# holds no `=`, so the message reads only one way.
signature_with! : Secret, Str, Str => Try(Str, [SigningFailed])
signature_with! = |key, name, value| {
	message = "roxum-cookie-v1\u(0)${name}=${value}".to_utf8()
	match Secret.derive!(key, [HmacSha256(SecretValue, Bytes(message))]) {
		Ok([mac]) => Ok(hex(mac))
		_ => Err(SigningFailed)
	}
}

hex : List(U8) -> Str
hex = |bytes| {
	var $digits = List.with_capacity(bytes.len() * 2)
	for byte in bytes {
		$digits = $digits.append(hex_digit(byte // 16, 'a')).append(hex_digit(byte % 16, 'a'))
	}
	Str.from_utf8_lossy($digits)
}

hex_digit : U8, U8 -> U8
hex_digit = |nibble, ten| if nibble < 10 {
	'0' + nibble
} else {
	ten + nibble - 10
}

# Looks at every byte, whatever it finds.
same_bytes : List(U8), List(U8) -> Bool
same_bytes = |left, right| {
	if left.len() != right.len() {
		return Bool.False
	}
	var $difference = 0
	var $index = 0
	while $index < left.len() {
		a : U8
		a = left.get($index) ?? 0
		b : U8
		b = right.get($index) ?? 0
		$difference = U8.bitwise_or($difference, U8.bitwise_xor(a, b))
		$index = $index + 1
	}
	$difference == 0
}

with_set_cookie : Reply, Str -> Reply
with_set_cookie = |reply, line|
	match HeaderValue.from_str(line) {
		Ok(value) => Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("set-cookie"), value }])
		# The checks in `add` and `remove` leave no control byte in the line.
		Err(_) => crash "Cookie: a checked Set-Cookie line holds no CR or LF"
	}

location_attributes : Str, Cookie.Domain -> Try(Str, [InvalidPath, InvalidDomain])
location_attributes = |path, domain| {
	if !path.starts_with("/") or !is_attribute_value(path) {
		return Err(InvalidPath)
	}
	match domain {
		HostOnly => Ok("; Path=${path}")
		Of(name) =>
			if name.is_empty() or !is_attribute_value(name) or name.to_utf8().contains(' ') {
				Err(InvalidDomain)
			} else {
				Ok("; Path=${path}; Domain=${name}")
			}
	}
}

refused_by_browsers : Cookie -> Bool
refused_by_browsers = |cookie| {
	none_without_secure = match cookie.same_site {
		None => !cookie.secure
		_ => Bool.False
	}
	host_only = match cookie.domain {
		HostOnly => Bool.True
		Of(_) => Bool.False
	}
	none_without_secure
		or (cookie.name.starts_with("__Secure-") and !cookie.secure)
		or (cookie.name.starts_with("__Host-") and !(cookie.secure and cookie.path == "/" and host_only))
}

is_token : Str -> Bool
is_token = |name| {
	bytes = name.to_utf8()
	!bytes.is_empty() and bytes.all(is_token_byte)
}

is_token_byte : U8 -> Bool
is_token_byte = |byte|
	is_unreserved(byte) or "!#$%&'*+^`|".to_utf8().contains(byte)

is_unreserved : U8 -> Bool
is_unreserved = |byte|
	(byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~'

# Printable ASCII that ends no attribute.
is_attribute_value : Str -> Bool
is_attribute_value = |value| value.to_utf8().all(|byte| byte >= 32 and byte < 127 and byte != ';')

# RFC 6265 cookie-octet without `%`, which starts an escape here.
is_cookie_octet : U8 -> Bool
is_cookie_octet = |byte|
	byte > 32 and byte < 127 and byte != '"' and byte != ',' and byte != ';' and byte != '\\' and byte != '%'

percent_encode : Str, (U8 -> Bool) -> Str
percent_encode = |text, keep| Str.from_utf8_lossy(percent_bytes(text, keep))

percent_bytes : Str, (U8 -> Bool) -> List(U8)
percent_bytes = |text, keep| {
	var $encoded = []
	for byte in text.to_utf8() {
		if keep(byte) {
			$encoded = $encoded.append(byte)
		} else {
			$encoded = $encoded.append('%').append(hex_digit(byte // 16, 'A')).append(hex_digit(byte % 16, 'A'))
		}
	}
	$encoded
}

pairs_of : List(U8) -> List({ name : Str, value : Str })
pairs_of = |line| {
	var $pairs = []
	for segment in split_at(line, ';') {
		match pair_of(trimmed(segment)) {
			Ok(pair) => {
				$pairs = $pairs.append(pair)
			}
			Err(_) => {}
		}
	}
	$pairs
}

pair_of : List(U8) -> Try({ name : Str, value : Str }, [NoPair])
pair_of = |segment| {
	match List.find_first_index(segment, |byte| byte == '=') {
		Ok(at) if at > 0 => {
			name = Str.from_utf8(trimmed(segment.take_first(at)))
			value = Str.from_utf8(percent_decoded(unquoted(trimmed(segment.drop_first(at + 1)))))
			match (name, value) {
				(Ok(text), Ok(decoded)) => Ok({ name: text, value: decoded })
				_ => Err(NoPair)
			}
		}
		_ => Err(NoPair)
	}
}

split_at : List(U8), U8 -> List(List(U8))
split_at = |bytes, separator| {
	var $parts = []
	var $current = []
	for byte in bytes {
		if byte == separator {
			$parts = $parts.append($current)
			$current = []
		} else {
			$current = $current.append(byte)
		}
	}
	$parts.append($current)
}

trimmed : List(U8) -> List(U8)
trimmed = |bytes| {
	var $rest = bytes
	while $rest.first() == Ok(' ') or $rest.first() == Ok('\t') {
		$rest = $rest.drop_first(1)
	}
	while $rest.last() == Ok(' ') or $rest.last() == Ok('\t') {
		$rest = $rest.drop_last(1)
	}
	$rest
}

unquoted : List(U8) -> List(U8)
unquoted = |bytes|
	if bytes.len() >= 2 and bytes.first() == Ok('"') and bytes.last() == Ok('"') {
		bytes.drop_first(1).drop_last(1)
	} else {
		bytes
	}

# `+` stays itself, unlike in a form. A malformed escape stays literal.
percent_decoded : List(U8) -> List(U8)
percent_decoded = |bytes| {
	var $decoded = []
	var $index = 0
	while $index < bytes.len() {
		byte = bytes.get($index) ?? 0
		high = hex_value(bytes.get($index + 1) ?? 0)
		low = hex_value(bytes.get($index + 2) ?? 0)
		match (byte == '%', high, low) {
			(Bool.True, Ok(h), Ok(l)) => {
				$decoded = $decoded.append(h * 16 + l)
				$index = $index + 3
			}
			_ => {
				$decoded = $decoded.append(byte)
				$index = $index + 1
			}
		}
	}
	$decoded
}

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |byte| {
	if byte >= '0' and byte <= '9' {
		return Ok(byte - '0')
	}
	if byte >= 'A' and byte <= 'F' {
		return Ok(byte - 'A' + 10)
	}
	if byte >= 'a' and byte <= 'f' {
		return Ok(byte - 'a' + 10)
	}
	Err(NotHex)
}

header : Str -> RequestHeader
header = |line| RequestHeader.{ name: HeaderName.("cookie"), value: line.to_utf8() }

# Whitespace, a pair without `=`, an empty name, a value with `=`, quotes,
# escapes, and `+` staying itself.
expect Cookie.all([header(" a=1;  b ; =x; c=d=e;e=\"q\";f=%41%zz+")]) == [
	{ name: "a", value: "1" },
	{ name: "c", value: "d=e" },
	{ name: "e", value: "q" },
	{ name: "f", value: "A%zz+" },
]

# Several fields read in order; not UTF-8 once decoded is left out.
expect Cookie.all([header("a=1"), header("b=%FF;c=2")]) == [{ name: "a", value: "1" }, { name: "c", value: "2" }]

# The first of a name; names compare exactly.
expect Cookie.get([header("a=1;a=2")], "a") == Ok("1")
expect Cookie.get([header("a=1")], "A") == Err(NotFound)

# The token and octet boundaries.
expect is_token("__Host-a.b") and !is_token("") and !is_token("a b") and !is_token("a=b") and !is_token("a;b") and !is_token("é")
expect percent_encode("a b;\"%é", is_cookie_octet) == "a%20b%3B%22%25%C3%A9"
expect pairs_of("x=${percent_encode("a b;\"%é", is_cookie_octet)}".to_utf8()) == [{ name: "x", value: "a b;\"%é" }]

# The comparison: equal, a difference at either end, another length.
expect same_bytes([1, 2, 3], [1, 2, 3])
expect !same_bytes([0, 2, 3], [1, 2, 3])
expect !same_bytes([1, 2, 0], [1, 2, 3])
expect !same_bytes([1, 2], [1, 2, 3])
