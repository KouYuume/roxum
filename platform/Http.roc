import HostBody
import HeaderValue

Http :: [].{

	## A request method. The union is closed: the host answers any other method,
	## including `CONNECT` and `TRACE`, with 501 Not Implemented and does not
	## call the app. Method names are case-sensitive on the wire, so `get` is
	## not `GET`.
	Method := [
		OPTIONS,
		GET,
		HEAD,
		POST,
		PUT,
		DELETE,
		PATCH,
		QUERY,
	].{
		is_eq : _

		## The method name as sent on the wire, such as `"GET"`.
		to_str : Http.Method -> Str
		to_str = |method|
			match method {
				OPTIONS => "OPTIONS"
				GET => "GET"
				HEAD => "HEAD"
				POST => "POST"
				PUT => "PUT"
				DELETE => "DELETE"
				PATCH => "PATCH"
				QUERY => "QUERY"
			}
	}

	## The HTTP version carried by request metadata. Http20 represents HTTP/2;
	## production listeners currently accept only HTTP/1.0 and HTTP/1.1.
	Version := [Http10, Http11, Http20].{
		is_eq : _
	}

	## An IP address. `V6` holds the eight 16-bit groups in order, already
	## converted from network byte order.
	IpAddr := [
		V4((U8, U8, U8, U8)),
		V6((U16, U16, U16, U16, U16, U16, U16, U16)),
	].{
		is_eq : _
	}

	## The transport peer: TCP has an IP and port; Unix has neither. Behind
	## a proxy this is the proxy until a trusted forwarding layer resolves it.
	RemoteAddr := [Tcp({ ip : Http.IpAddr, port : U16 }), Unix].{
		is_eq : _
	}

	## A header field name. The host lowercases the names of received request
	## headers, so compare them with lowercase strings such as `"host"`. A name
	## built in Roc code is not checked or lowercased; build it in lowercase
	## when it must match received headers. In a response, the host rejects a
	## name that is not a valid HTTP token.
	HeaderName := Str.{
		is_eq : _
		to_hash : _

		## Returns the name as a string.
		inner = |HeaderName.(value)| value
	}

	## A received header field. The value holds the bytes as received, which
	## need not be valid UTF-8; convert explicitly when text is needed.
	RequestHeader := {
		## Lowercased by the host for received requests.
		name : Http.HeaderName,

		## Raw bytes of the field value.
		value : List(U8),
	}.{
		is_eq : _
	}

	## A header field to send. The value cannot contain CR or LF. The host
	## writes nothing and answers 500 when a name is not a valid token, a value
	## contains another control character, or the name is `content-length`,
	## `transfer-encoding`, or `connection` (compared without regard to case);
	## the host sets message framing itself.
	ResponseHeader := {
		name : Http.HeaderName,
		value : HeaderValue,
	}.{
		is_eq : _
	}

	## The body of a request. A handler sees `Empty` or `Bytes`: the platform has
	## received the body before it runs. `Stream` is how the host hands a body to the
	## platform; no handler or layer gets one. For parts as they arrive, use
	## `Handler.streaming`.
	RequestBody := [
		Empty,
		Bytes(List(U8)),
		Stream(Http.RequestStream),
	].{}

	## The platform's handle for reading the body of the current request from the
	## connection (`Pipeline`). The type is opaque, so app code cannot build one, and
	## this module does not expose it. A handle is valid only while its request runs.
	##
	## The host receives a small body (up to 64 KiB) before the platform asks for it,
	## so reading it does not wait. A larger body is read from the connection as the
	## platform reads; while a read waits, the thread serves other requests. A client
	## that sent `Expect: 100-continue` gets `100 Continue` at the first read that
	## waits for it.
	RequestStream :: U64.{

		## Reads the next part of the request body as a stream: only this part
		## is held, so a body of any size can be read in parts. Fails with
		## `TooLarge` past `Server.Limits.maximum_streamed_body_bytes` (none
		## by default) or a route's `BodyLimit.streamed`, and with `TimedOut`
		## when no bytes arrived for `Server.Timeouts.request_body_milliseconds`.
		##
		## `maximum_bytes` must be at least 1, or the read returns
		## `InvalidLimit`; larger values are capped at 16 KiB. A `Chunk` is never
		## empty. Read until `End`; after the last byte of the body, the next
		## read returns `End`. `BadRequest` means invalid framing or a
		## connection that ended early, and `Failed` is an internal error.
		## After a failure, later reads return the same result.
		read! = |RequestStream.(token), maximum_bytes| HostBody.read!(token, maximum_bytes, Bool.False)

		## Like `read!`, for a body read whole into memory, as `Extract.bytes`
		## does. When the rest of a Content-Length body has already been
		## received, a `maximum_bytes` above 16 KiB returns all of it in one
		## `Chunk`. It fails with `TooLarge` past `Server.Limits.maximum_body_bytes`
		## (2 MiB by default) or a route's `BodyLimit.whole`, and with
		## `TimedOut` when the whole body took longer than
		## `Server.Timeouts.request_body_milliseconds`.
		read_whole! = |RequestStream.(token), maximum_bytes| HostBody.read!(token, maximum_bytes, Bool.True)

		## Sets this request's limit for a body read whole into memory. The
		## `BodyLimit.whole` layer calls it.
		limit_whole! = |RequestStream.(token), bytes| HostBody.limit_whole!(token, bytes)

		## Sets this request's limit for a body read as a stream. The
		## `BodyLimit.streamed` layer calls it.
		limit_streamed! = |RequestStream.(token), bytes| HostBody.limit_streamed!(token, bytes)
	}

	## The body of a response. The host writes `Content-Length`, except on
	## 204 and 304 responses, and does not send the body of a response to a
	## `HEAD` request. A body written as it goes is `Reply.stream`.
	ResponseBody := [
		Empty,
		Bytes(List(U8)),
	].{}

	## A request as passed to the app. For requests received from the network,
	## the host fills every field; a request built in Roc code, such as in a
	## test, is not validated.
	Request := {
		method : Http.Method,
		version : Http.Version,

		## The request target exactly as received, including any query.
		raw_target : List(U8),

		## The path part of the target, before percent-decoding. The host
		## answers 400 when it contains an empty segment (`//`), `.`, or `..`.
		## For an absolute-form target it is the path after the authority, or
		## `/` when there is none; for an asterisk-form target it is `*`.
		path : Str,

		## The bytes after the first `?` of the target, without the `?`, not
		## parsed or decoded. Empty when the target has no query.
		query : List(U8),

		## The header fields in received order, with duplicates kept.
		headers : List(Http.RequestHeader),
		body : Http.RequestBody,
		remote_addr : Http.RemoteAddr,

		## The request's ID, which the host's logs use too. The host decides it
		## as `listen.request_id` says (`Server.RequestIdSource`); the
		## request's own `x-request-id` fields stay in `headers` as received.
		request_id : Str,
	}.{
		# raw headers remain lossless. Routing/security decisions use this authority:
		# absolute-form overrides Host; origin/asterisk-form use Host.
		## Returns the effective authority (host and optional port) of the
		## request. For an absolute-form target such as
		## `http://example.com:8080/path`, it is the authority in the target and
		## any `host` header is ignored. For an origin-form or asterisk-form
		## target, it is the value of the first `host` header. Returns
		## `Err(MissingAuthority)` when neither is present, which HTTP/1.0
		## allows. Use this instead of reading the `host` header directly for
		## virtual hosts, authorization, and URL generation.
		authority : Http.Request -> Try(List(U8), [MissingAuthority])
		authority = |request| {
			target = Str.from_utf8_lossy(request.raw_target)
			if !Str.starts_with(target, "/") and target != "*" {
				match List.get(Str.split_on(target, "://"), 1) {
					Ok(remainder) => {
						before_path = match List.first(Str.split_on(remainder, "/")) {
							Ok(value) => value
							Err(_) => ""
						}
						before_query = match List.first(Str.split_on(before_path, "?")) {
							Ok(value) => value
							Err(_) => ""
						}
						return Ok(before_query.to_utf8())
					}
					Err(_) => return Err(MissingAuthority)
				}
			}
			for header in request.headers {
				if Http.HeaderName.inner(header.name) == "host" {
					return Ok(header.value)
				}
			}
			Err(MissingAuthority)
		}
	}

	## A response to send. The host validates the whole head before writing
	## any byte; when validation fails it sends 500 instead and closes the
	## connection. The host adds a `Date` header when the response has none.
	Response := {
		## Must be 200 to 599; 1xx responses are not supported. A 204, 205, or
		## 304 response must have an empty body.
		status : U16,
		headers : List(Http.ResponseHeader),
		## Final fields for finite HTTP/2 responses. Empty means no trailers.
		## HTTP/1 and streamed/file responses reject nonempty trailers.
		trailers : List(Http.ResponseHeader) ?? [],
		body : Http.ResponseBody,
	}
}

expect {
	# Accepted target equivalence classes: origin, asterisk, absolute with
	# empty/nonempty path, query-only suffix, port and IPv6 authority.
	cases = [
		("/path", "fallback.example"),
		("//path", "fallback.example"),
		("*", "fallback.example"),
		("http://target.example", "target.example"),
		("http://target.example?x=1", "target.example"),
		("http://target.example/path?x=1", "target.example"),
		("HTTPS://target.example:443/path", "target.example:443"),
		("http://[::1]:8080/path", "[::1]:8080"),
	]
	List.all(
		cases,
		|(target, expected)| {
			request = Http.Request.{
				method: Http.Method.GET,
				version: Http.Version.Http11,
				raw_target: target.to_utf8(),
				path: "/path",
				query: [],
				headers: [Http.RequestHeader.{ name: Http.HeaderName.("host"), value: "fallback.example".to_utf8() }],
				body: Http.RequestBody.Empty,
				remote_addr: Http.RemoteAddr.Tcp({ ip: Http.IpAddr.V4((127, 0, 0, 1)), port: 1 }),
				request_id: "test",
			}
			Http.Request.authority(request) == Ok(expected.to_utf8())
		},
	)
}

expect {
	# HTTP/1.0 origin-form may omit Host; absence remains explicit.
	request = Http.Request.{
		method: Http.Method.GET,
		version: Http.Version.Http10,
		raw_target: "/".to_utf8(),
		path: "/",
		query: [],
		headers: [],
		body: Http.RequestBody.Empty,
		remote_addr: Http.RemoteAddr.Tcp({ ip: Http.IpAddr.V4((127, 0, 0, 1)), port: 1 }),
		request_id: "test",
	}
	Http.Request.authority(request) == Err(MissingAuthority)
}


expect {
	versions = [Http.Version.Http10, Http.Version.Http11, Http.Version.Http20]
	List.map(versions, |version|
		match version {
			Http.Version.Http10 => 10
			Http.Version.Http11 => 11
			Http.Version.Http20 => 20
		},
	) == [10, 11, 20]
}
