import ContentCoding
import HeaderValue
import HostCompress
import Http
import HttpError
import Middleware
import Reply

## Compressing response bodies with gzip. Apply the layer to the
## routes whose responses should be compressed, with `Router.layer` or
## `MethodRouter.layer`:
##
## ```roc
## routes = Router.new.route(...).layer(Compression.layer(Compression.Options.{}))
## ```
##
## A response is compressed when the client accepts gzip, its body has more
## than `above_bytes` bytes (a body written as it goes, `Reply.stream`, or
## a file is compressed as it is sent), it has no `content-encoding`
## yet, and its
## `content-type` is not an image (but SVG), gRPC, or server-sent events
## (the same as tower-http's `CompressionLayer`). Such a response gets
## `vary: accept-encoding` whether or not this client gets it compressed.
## The host compresses off the request threads.
##
## Do not compress responses that put a secret and text from the request
## in one body, on TLS: their compressed length can tell the secret
## (BREACH).
Compression := [].{

	## `above_bytes`: smaller bodies are sent as they are (32 by default).
	Options := {
		above_bytes : U64 ?? 32,
	}

	layer : Compression.Options -> List(Middleware.Stage(model, tag, provided))
	layer = |options| {
		marked = { above_bytes: options.above_bytes }
		[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.compressible(reply, marked))]
	}

	## A content coding `decompress!` reads.
	Coding := [Gzip, Zstd]

	## Decompresses `bytes`, such as a response body an outside API sent
	## with `content-encoding: gzip`. A body that would be larger
	## than `maximum_bytes` is `DecompressedTooLarge` as soon as it passes
	## the limit, so a small body that expands to gigabytes takes no more
	## memory than that. The host decompresses off the request threads.
	decompress! : List(U8), Compression.Coding, U64 => Try(List(U8), [DecompressedTooLarge, DecompressFailed])
	decompress! = |bytes, coding, maximum_bytes| {
		code = match coding {
			Compression.Coding.Gzip => 0
			Compression.Coding.Zstd => 1
		}
		match HostCompress.decompress!(bytes, code, maximum_bytes) {
			HostCompress.Decompressed.Decompressed(decompressed) => Ok(decompressed)
			HostCompress.Decompressed.TooLarge => Err(DecompressedTooLarge)
			HostCompress.Decompressed.Invalid => Err(DecompressFailed)
		}
	}

	## A layer that decompresses a request body sent with `Content-Encoding: gzip`
	## or `zstd` before the handler reads it. A body with no
	## `Content-Encoding`, or `identity`, passes through. Answers 415 for another
	## coding before the body is received, 413 when the body would decompress to
	## more than `maximum_bytes`, and 400 when it is not valid in its coding. A
	## `Handler.streaming` handler gets the parts as they were sent.
	decompress_requests : U64 -> List(Middleware.Stage(model, tag, provided))
	decompress_requests = |maximum_bytes| [
		Middleware.Stage.BeforeBody(
			|_model, head|
				match request_coding(head.headers) {
					Ok(_) => Ok(head)
					Err(Unsupported) => Err(Reply.error(HttpError.make(415, "unsupported Content-Encoding")))
				},
		),
		Middleware.Stage.AfterBody(
			|_model, head, body|
				match request_coding(head.headers) {
					Err(Unsupported) | Ok(None) => Ok(body)
					Ok(Some(coding)) =>
						match Compression.decompress!(body, coding, maximum_bytes) {
							Ok(decompressed) => Ok(decompressed)
							Err(DecompressedTooLarge) => Err(Reply.error(HttpError.make(413, "request body too large")))
							Err(DecompressFailed) => Err(Reply.error(HttpError.bad_request("request body is not valid in its Content-Encoding")))
						},
				},
		),
	]

	## Compresses `response` for `request` when it should be. Platform code
	## only.
	respond! : Http.Request, { above_bytes : U64 }, Http.Response => Http.Response
	respond! = |request, options, response|
		match response.body {
			Http.ResponseBody.Bytes(bytes) =>
				if !Compression.eligible(response.status, response.headers, List.len(bytes), options.above_bytes) {
					response
				} else {
					varied = with_header(response.headers, "vary", "accept-encoding")
					compressed = if accepts_gzip(request) {
						HostCompress.gzip!(bytes)
					} else {
						[]
					}
					if List.is_empty(compressed) {
						{ ..response, headers: varied }
					} else {
						{ ..response, headers: with_header(varied, "content-encoding", "gzip"), body: Http.ResponseBody.Bytes(compressed) }
					}
				}
			Http.ResponseBody.Empty => response
		}

	## The head of a body sent as it goes, written or a file: with
	## `content-encoding: gzip` and `gzip: Bool.True` when the host is to
	## compress it. `length` is the body's, when it is known. Platform code
	## only.
	plan : Http.Request, { above_bytes : U64 }, Http.Response, Try(U64, [Unknown]) -> { headers : List(Http.ResponseHeader), gzip : Bool }
	plan = |request, options, response, length| {
		large = match length {
			Ok(known) => known > options.above_bytes
			Err(Unknown) => Bool.True
		}
		if !large or !Compression.eligible_type(response.status, response.headers) {
			{ headers: response.headers, gzip: Bool.False }
		} else {
			varied = with_header(response.headers, "vary", "accept-encoding")
			if accepts_gzip(request) {
				{ headers: with_header(varied, "content-encoding", "gzip"), gzip: Bool.True }
			} else {
				{ headers: varied, gzip: Bool.False }
			}
		}
	}

	## Whether a response of this status, headers, and body length may be
	## compressed.
	eligible : U16, List(Http.ResponseHeader), U64, U64 -> Bool
	eligible = |status, headers, length, above_bytes| length > above_bytes and Compression.eligible_type(status, headers)

	## Whether a response of this status and headers may be compressed,
	## whatever its length.
	eligible_type : U16, List(Http.ResponseHeader) -> Bool
	eligible_type = |status, headers|
		if status == 204 or status == 304 or has_header(headers, "content-encoding") {
			Bool.False
		} else {
			media = match List.find_first(headers, |header| lower(Http.HeaderName.inner(header.name)) == "content-type") {
				Ok(header) => lower(HeaderValue.inner(header.value))
				Err(_) => ""
			}
			image = Str.starts_with(media, "image/") and !Str.starts_with(media, "image/svg+xml")
			!(image or Str.starts_with(media, "application/grpc") or Str.starts_with(media, "text/event-stream"))
		}
}

accepts_gzip : Http.Request -> Bool
accepts_gzip = |request|
	match List.find_first(request.headers, |header| Http.HeaderName.inner(header.name) == "accept-encoding") {
		Ok(header) => ContentCoding.accepts(Str.from_utf8_lossy(header.value), "gzip")
		Err(_) => Bool.False
	}

has_header : List(Http.ResponseHeader), Str -> Bool
has_header = |headers, name| List.any(headers, |header| lower(Http.HeaderName.inner(header.name)) == name)

with_header : List(Http.ResponseHeader), Str, Str -> List(Http.ResponseHeader)
with_header = |headers, name, text|
	match HeaderValue.from_str(text) {
		Ok(value) => List.append(headers, Http.ResponseHeader.{ name: Http.HeaderName.(name), value })
		Err(CrlfInjection) => headers
	}

lower : Str -> Str
lower = |text| Str.from_utf8_lossy(
	List.map(
		Str.to_utf8(text),
		|byte| if byte >= 'A' and byte <= 'Z' {
			byte + 32
		} else {
			byte
		},
	),
)

## The coding a request body arrived in. More than one is not supported.
request_coding = |headers|
	match List.keep_if(headers, |header| header.name == Http.HeaderName.("content-encoding")) {
		[] => Ok(None)
		[header] =>
			match ascii_lower_str(Str.trim(Str.from_utf8_lossy(header.value))) {
				"identity" => Ok(None)
				"gzip" | "x-gzip" => Ok(Some(Compression.Coding.Gzip))
				"zstd" => Ok(Some(Compression.Coding.Zstd))
				_ => Err(Unsupported)
			}
		_ => Err(Unsupported)
	}

ascii_lower_str = |text| Str.from_utf8_lossy(List.map(text.to_utf8(), |byte| if byte >= 'A' and byte <= 'Z' { byte + 32 } else { byte }))

expect Compression.eligible(200, [], 33, 32)
expect !Compression.eligible(200, [], 32, 32)
expect !Compression.eligible(304, [], 1000, 32)
expect !Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("Content-Encoding"), value: "br" }], 1000, 32)
expect !Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: "image/png" }], 1000, 32)
expect Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: "image/svg+xml" }], 1000, 32)
expect !Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: "text/event-stream" }], 1000, 32)
expect !Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: "application/grpc+proto" }], 1000, 32)
expect Compression.eligible(200, [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: "application/json" }], 1000, 32)

# Vary must include negotiation for both encoded and identity responses,
# with no prior field, an unrelated field, or an existing encoding field.
expect {
	List.all(
		["gzip", "gzip;q=0"],
		|accepted| {
			request = Http.Request.{
				method: Http.Method.GET,
				version: Http.Version.Http11,
				raw_target: "/".to_utf8(),
				path: "/",
				query: [],
				headers: [Http.RequestHeader.{ name: Http.HeaderName.("accept-encoding"), value: accepted.to_utf8() }],
				body: Http.RequestBody.Empty,
				remote_addr: Http.RemoteAddr.{ ip: Http.IpAddr.V4((127, 0, 0, 1)), port: 1 },
				request_id: "test",
			}
			List.all(
				[[], [Http.ResponseHeader.{ name: Http.HeaderName.("Vary"), value: "Origin" }], [Http.ResponseHeader.{ name: Http.HeaderName.("vary"), value: "accept-encoding" }]],
				|headers| {
					List.all(
						[Ok(33), Err(Unknown)],
						|length| {
							planned = Compression.plan(request, { above_bytes: 32 }, { status: 200, headers, body: Http.ResponseBody.Empty }, length)
							planned.gzip == (accepted == "gzip") and
								List.all(headers, |header| List.contains(planned.headers, header)) and
									List.any(planned.headers, |header| lower(Http.HeaderName.inner(header.name)) == "vary" and HeaderValue.inner(header.value) == "accept-encoding")
						},
					)
				},
			)
		},
	)
}
