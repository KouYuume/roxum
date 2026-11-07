import HttpUrl
import HttpWire
import http.Request
import http.Response
import pf.Compression
import pf.Instant
import pf.Secret
import pf.Server
import pf.Tcp

## An HTTP/1.1 client over roxum's `Tcp` (D7): the protocol is Roc, the
## host keeps the connections. Requests and responses are
## [roc-lang/http](https://github.com/roc-lang/http)'s `Request` and
## `Response` (D15). Make a client in `init!` and keep it in the model.
##
## ```roc
## # In init!:
## client = HttpClient.client!(HttpClient.Config.{})?
##
## # In a handler:
## request = Request.from_method(Method.GET).with_uri("https://tax.example.com/rates/JP")
## response = HttpClient.send_with!(model.client, request, HttpClient.SendOptions.{
##     secret_headers: [{ name: "Authorization", prefix: "Bearer ", secret: model.tax_token }],
## })?
## ```
##
## - One client sends to any URL. The worker's clients share the
##   connections: at most 64 in use at once per origin, idle ones close
##   after 90 seconds, and at most 100 stay idle
## - A 4xx or 5xx response is `Ok`; look at its status
## - Redirects are followed up to `maximum_redirects`. Moving to another
##   origin drops the secret headers and `Authorization`, `Cookie`,
##   `Proxy-Authorization`, and `WWW-Authenticate`. A redirect from https to
##   http is `HttpClientInsecureRedirect`
## - When an idle connection turns out closed, the request is sent again on
##   a new connection: any request that left nothing, and GET, HEAD,
##   OPTIONS, or TRACE when no response came back
## - With `decompress` (on by default), a request without `Accept-Encoding`
##   is sent with `Accept-Encoding: gzip, zstd`, and a response with
##   `Content-Encoding: gzip` or `zstd` comes back decompressed, without
##   those two headers and `Content-Length`, whoever asked for it (as
##   reqwest does). `maximum_body_bytes` applies to the body decompressed
##   too. Other codings, such as `br`, come back as they are
HttpClient := [].{

	## The CA certificates trusted for https: the system's, or those in a PEM
	## file at an absolute path.
	Ca := [System, File(Str)]

	Config := {
		## The whole exchange, redirects included. A request's own timeout
		## (`Request.with_timeout`) takes precedence.
		timeout_milliseconds : U64 ?? 30_000,
		maximum_body_bytes : U64 ?? 8_388_608,
		maximum_redirects : U64 ?? 10,
		retry_on_stale_connection : Bool ?? Bool.True,
		ca : HttpClient.Ca ?? HttpClient.Ca.System,
		decompress : Bool ?? Bool.True,
	}

	## A header whose value the host writes: `prefix`, then the secret
	## (D14). The value never passes through Roc.
	SecretHeader : { name : Str, prefix : Str, secret : Secret }

	SendOptions := {
		secret_headers : List(HttpClient.SecretHeader) ?? [],
	}

	Client :: {
		timeout : U64,
		maximum_body_bytes : U64,
		maximum_redirects : U64,
		retry : Bool,
		tls : Tcp.Tls,
		decompress : Bool,
	}

	## The process's connection limits, shared by all its clients: requests
	## in flight at once per origin (`Auto`: 64 for each thread; `Fixed`
	## takes 1 to 1024 for each thread), idle connections kept across all
	## origins (`Auto`: 100 for each thread; `Fixed` takes 0 to 65536 for
	## each thread), and how long one may stay idle.
	Limits := {
		maximum_requests_per_host : Server.Count ?? Server.Count.Auto,
		maximum_idle_connections : Server.Count ?? Server.Count.Auto,
		idle_timeout_milliseconds : U64 ?? 90_000,
	}

	## Changes the process's connection limits. Call it in `init!`, before the
	## first request; later, or with a limit outside its range, it fails.
	configure! : HttpClient.Limits => Try({}, [HttpClientInvalidConfig])
	configure! = |HttpClient.Limits.({ maximum_requests_per_host, maximum_idle_connections, idle_timeout_milliseconds })|
		Tcp.configure_origins!(
			Tcp.OriginLimits.{
				connections_per_origin: maximum_requests_per_host,
				idle_connections: maximum_idle_connections,
				idle_timeout_milliseconds,
			},
		).map_err(|TcpInvalidOriginLimits| HttpClientInvalidConfig)

	## Makes a client. It fails when the CA certificates for https cannot be
	## loaded, so call it in `init!`.
	client! : HttpClient.Config => Try(HttpClient.Client, [HttpClientCaUnavailable, HttpClientInvalidConfig])
	client! = |config| {
		if config.timeout_milliseconds == 0 or config.maximum_body_bytes == 0 {
			return Err(HttpClientInvalidConfig)
		}
		tls = match config.ca {
			System => Tcp.Tls.On
			File(path) => Tcp.Tls.OnWithCaFile(path)
		}
		match Tcp.check_ca!(tls) {
			Ok({}) => {}
			Err(TcpCaUnavailable) => return Err(HttpClientCaUnavailable)
		}
		Ok(
			HttpClient.Client.(
				{
					timeout: config.timeout_milliseconds,
					maximum_body_bytes: config.maximum_body_bytes,
					maximum_redirects: config.maximum_redirects,
					retry: config.retry_on_stale_connection,
					tls,
					decompress: config.decompress,
				},
			),
		)
	}

	## Sends `request` and returns the final response, after redirects.
	send! = |client, request| HttpClient.send_with!(client, request, HttpClient.SendOptions.{})

	## `send!` with options for this request, such as secret headers.
	send_with! = |HttpClient.Client.(client), request, HttpClient.SendOptions.({ secret_headers })| {
		started = Instant.now!({})
		timeout = match request.timeout() {
			TimeoutMilliseconds(milliseconds) => milliseconds
			NoTimeout => client.timeout
		}
		method = request.method_str()
		HttpWire.check_method(method)?
		given = request.headers().map(|header| (header.name, header.value))
		headers = if client.decompress and HttpWire.header(given, "accept-encoding") == Err(NotFound) {
			given.append(("accept-encoding", "gzip, zstd"))
		} else {
			given
		}
		for (name, value) in headers {
			HttpWire.check_header(name, value)?
		}
		for secret_header in secret_headers {
			HttpWire.check_header(secret_header.name, secret_header.prefix)?
		}
		url = HttpUrl.parse(request.uri()).map_err(|InvalidUrl(problem)| HttpClientInvalidUrl(problem))?
		var $hop = { url, method, headers, body: request.body(), secrets: secret_headers }
		var $redirects = 0
		while Bool.True {
			hop = $hop
			message = exchange!(client, hop, started, timeout)?
			location = HttpWire.header(message.headers, "location")
			redirect = [301, 302, 303, 307, 308].contains(message.status)
			match (redirect, location) {
				(Bool.True, Ok(target)) => {
					if $redirects >= client.maximum_redirects {
						return Err(HttpClientTooManyRedirects)
					}
					$hop = next_hop(hop, message.status, target)?
					$redirects = $redirects + 1
				}
				_ => return Ok(response_of(decoded!(client, message)?))
			}
		}
	}
}

Hop : {
	url : HttpUrl.Parts,
	method : Str,
	headers : List((Str, Str)),
	body : List(U8),
	secrets : List(HttpClient.SecretHeader),
}

## The request a redirect asks for (RFC 9110 §15.4): 301, 302, and 303 turn
## a request other than GET or HEAD into a GET without a body, as browsers,
## Go, and reqwest do; 307 and 308 repeat it.
next_hop : Hop, U16, Str -> Try(Hop, [HttpClientInvalidUrl(Str), HttpClientInsecureRedirect])
next_hop = |hop, status, location| {
	url = HttpUrl.resolve(hop.url, location).map_err(|InvalidUrl(problem)| HttpClientInvalidUrl(problem))?
	if hop.url.scheme == Https and url.scheme == Http {
		return Err(HttpClientInsecureRedirect)
	}
	to_get = status <= 303 and hop.method != "GET" and hop.method != "HEAD"
	(method, body, kept) = if to_get {
		("GET", [], hop.headers.drop_if(|(name, _)| ["content-type", "content-encoding", "content-language"].any(|dropped| name.caseless_ascii_equals(dropped))))
	} else {
		(hop.method, hop.body, hop.headers)
	}
	if HttpUrl.same_origin(hop.url, url) {
		Ok({ ..hop, url: url, method: method, body: body, headers: kept })
	} else {
		sensitive = ["authorization", "cookie", "proxy-authorization", "www-authenticate"]
		Ok({ url, method, body, headers: kept.drop_if(|(name, _)| sensitive.any(|dropped| name.caseless_ascii_equals(dropped))), secrets: [] })
	}
}

## The message with its body decompressed, when the client decompresses and
## the body is in gzip or Zstandard.
decoded! = |client, message| {
	coding = match HttpWire.header(message.headers, "content-encoding") {
		Ok(value) => {
			named = value.trim()
			if named.caseless_ascii_equals("gzip") or named.caseless_ascii_equals("x-gzip") {
				Ok(Compression.Coding.Gzip)
			} else if named.caseless_ascii_equals("zstd") {
				Ok(Compression.Coding.Zstd)
			} else {
				Err(Kept)
			}
		}
		Err(NotFound) => Err(Kept)
	}
	match coding {
		Ok(known) if client.decompress and !message.body.is_empty() =>
			match Compression.decompress!(message.body, known, client.maximum_body_bytes) {
				Ok(body) => {
					framing = ["content-encoding", "content-length"]
					Ok({ ..message, body, headers: message.headers.drop_if(|(name, _)| framing.any(|dropped| name.caseless_ascii_equals(dropped))) })
				}
				Err(DecompressedTooLarge) => Err(HttpClientBodyTooLarge)
				Err(DecompressFailed) => Err(HttpClientInvalidResponse("the body does not decompress as its content-encoding says"))
			}
		_ => Ok(message)
	}
}

response_of : HttpWire.Message -> Response
response_of = |message|
	Response.from_status(message.status)
		.with_headers(message.headers.map(|(name, value)| { name, value }))
		.with_body(message.body)

## One request on one connection, sent again on a new connection when an
## idle one turns out closed (see `HttpClient`).
exchange! = |client, hop, started, timeout|
	match attempt!(client, hop, started, timeout, Bool.True) {
		Err(Stale) if client.retry => without_stale(attempt!(client, hop, started, timeout, Bool.False))
		other => without_stale(other)
	}

without_stale = |result|
	match result {
		Ok(message) => Ok(message)
		Err(Stale) => Err(HttpClientClosed)
		Err(TcpBusy) => Err(HttpClientBusy)
		Err(TcpResolveFailed) => Err(TcpResolveFailed)
		Err(TcpResolveTimedOut) => Err(TcpResolveTimedOut)
		Err(TcpConnectFailed) => Err(TcpConnectFailed)
		Err(TcpConnectTimedOut) => Err(TcpConnectTimedOut)
		Err(TcpTlsFailed) => Err(TcpTlsFailed)
		Err(HttpClientTimedOut) => Err(HttpClientTimedOut)
		Err(HttpClientClosed) => Err(HttpClientClosed)
		Err(HttpClientInvalidHeader(name)) => Err(HttpClientInvalidHeader(name))
		Err(HttpClientInvalidResponse(problem)) => Err(HttpClientInvalidResponse(problem))
		Err(HttpClientBodyTooLarge) => Err(HttpClientBodyTooLarge)
		Err(HttpClientOverloaded) => Err(HttpClientOverloaded)
	}

attempt! = |client, hop, started, timeout, reuse_idle| {
	tls = match hop.url.scheme {
		Http => Tcp.Tls.Off
		Https => client.tls
	}
	origin = Tcp.Origin.{ host: hop.url.host, port: hop.url.port, tls, reuse_idle }
	Tcp.with_origin!(
		origin,
		remaining_milliseconds!(started, timeout)?,
		|connection| {
			reused = !Tcp.is_new!(connection)
			idempotent = ["GET", "HEAD", "OPTIONS", "TRACE"].contains(hop.method)
			head = HttpWire.request_head({ method: hop.method, target: hop.url.target, authority: hop.url.authority, headers: hop.headers, body_length: hop.body.len() })
			match Tcp.write!(connection, head, remaining_on_connection!(connection, started, timeout)?) {
				Ok({}) => {}
				Err(TcpUnsent) => return Err(
					if reused {
						Stale
					} else {
						HttpClientClosed
					},
				)
				Err(TcpTimedOut) => return Err(HttpClientTimedOut)
				Err(_) => return Err(HttpClientClosed)
			}
			for secret_header in hop.secrets {
				line = [Concat(Bytes("${secret_header.name}: ${secret_header.prefix}".to_utf8()), Concat(SecretValue, Bytes("\r\n".to_utf8())))]
				match Tcp.write_derived!(connection, secret_header.secret, line, remaining_on_connection!(connection, started, timeout)?) {
					Ok({}) => {}
					Err(TcpSecretRefused) => {
						Tcp.discard!(connection)
						return Err(HttpClientInvalidHeader(secret_header.name))
					}
					Err(TcpTimedOut) => return Err(HttpClientTimedOut)
					Err(_) => return Err(HttpClientClosed)
				}
			}
			match Tcp.write!(connection, "\r\n".to_utf8().concat(hop.body), remaining_on_connection!(connection, started, timeout)?) {
				Ok({}) => {}
				Err(TcpTimedOut) => return Err(HttpClientTimedOut)
				Err(_) => return Err(HttpClientClosed)
			}
			# A reused connection that ends before any byte of the response
			# was most likely closed by the server while idle.
			stale = |received_any| if reused and idempotent and !received_any {
				Stale
			} else {
				HttpClientClosed
			}
			var $reader = HttpWire.reader(hop.method == "HEAD", client.maximum_body_bytes)
			var $received_any = Bool.False
			while Bool.True {
				outcome = match Tcp.read!(connection, 65_536, remaining_on_connection!(connection, started, timeout)?) {
					Ok(bytes) => {
						$received_any = Bool.True
						HttpWire.advance($reader, bytes, Bool.False)
					}
					Err(TcpClosed) => HttpWire.advance($reader, [], Bool.True)
					Err(TcpTimedOut) => return Err(HttpClientTimedOut)
					Err(TcpOverloaded) => return Err(HttpClientOverloaded)
					Err(_) => return Err(stale($received_any))
				}
				match outcome {
					Done(message) => {
						if !message.reusable or HttpWire.asks_to_close(hop.headers) {
							Tcp.discard!(connection)
						}
						return Ok(message)
					}
					NeedMore(next) => {
						$reader = next
					}
					EndedEarly => return Err(stale($received_any))
					TooLarge => {
						Tcp.discard!(connection)
						return Err(HttpClientBodyTooLarge)
					}
					Invalid(problem) => {
						Tcp.discard!(connection)
						return Err(HttpClientInvalidResponse(problem))
					}
				}
			}
		},
	)
}

## What is left of the exchange's time, rounded down; none left is
## `HttpClientTimedOut`.
remaining_milliseconds! : Instant, U64 => Try(U64, [HttpClientTimedOut])
remaining_milliseconds! = |started, timeout| {
	elapsed = Instant.nanoseconds_between(started, Instant.now!({})) // 1_000_000
	if elapsed >= timeout {
		Err(HttpClientTimedOut)
	} else {
		Ok(timeout - elapsed)
	}
}

remaining_on_connection! = |connection, started, timeout|
	match remaining_milliseconds!(started, timeout) {
		Ok(left) => Ok(left)
		Err(problem) => {
			Tcp.discard!(connection)
			Err(problem)
		}
	}
