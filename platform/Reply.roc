import ContentDisposition
import FileRoot
import Http
import HeaderValue
import HttpError
import JsonLines
import MediaType
import Status
import ResponseWriter

## What a handler returns. A `Reply` describes a response and is converted to
## an `Http.Response` by `Respond.to_response` after the handler returns.
## Handlers return `Try(Reply, Reply)`, so both success and early failure are
## replies.
Reply := [
	Text(Str),
	Json(Str),
	Bytes(List(U8), MediaType),
	Empty,
	StatusOnly(Status),
	WithStatus(Status, Reply),
	WithHeaders(List(Http.ResponseHeader), Reply),
	ReplaceHeaders(List(Http.ResponseHeader), Reply),
	Full(Http.Response),
	Err(HttpError),
	Routed(Str, Reply),
	Writes(ResponseWriter.Options, (ResponseWriter => Try({}, [StreamClosed]))),
	File(FileRoot, Str),
	Compressible({ above_bytes : U64 }, Reply),
].{
	## A 200 response whose body `write!` writes as it goes: after the
	## middleware, the platform sends the head and calls `write!`, and the
	## body ends when it returns. `write!` may wait for anything, as a
	## handler does, and other requests go on meanwhile. The body uses chunked
	## transfer coding on HTTP/1.1; on HTTP/1.0 it ends by closing the
	## connection. Add headers, such as `content-type`, with `with_headers`.
	##
	## ```roc
	## Reply.stream(|writer| {
	##     ResponseWriter.write!(writer, "first\n".to_utf8())?
	##     Sleep.millis!(1_000)
	##     ResponseWriter.write!(writer, "second\n".to_utf8())
	## })
	## ```
	stream = |write!| Reply.(Writes(ResponseWriter.Options.{}, write!))
	## Like `stream`, with `options`, such as keep-alive bytes for a body that
	## is quiet for long:
	##
	## ```roc
	## Reply.stream_with(
	##     ResponseWriter.Options.{ keep_alive: ResponseWriter.KeepAlive.Every({ milliseconds: 15_000, bytes: ":\n\n".to_utf8() }) },
	##     write_events!,
	## )
	## ```
	stream_with = |options, write!| Reply.(Writes(options, write!))
	## The function that writes the reply's body, for a reply from `stream`,
	## looking through wrappers. Platform code only.
	writer : Reply -> Try({ options : ResponseWriter.Options, write! : (ResponseWriter => Try({}, [StreamClosed])) }, [NotStreamed])
	writer = |reply|
		match reply {
			Writes(options, write!) => Ok({ options, write! })
			WithStatus(_, inner) | WithHeaders(_, inner) | ReplaceHeaders(_, inner) | Routed(_, inner) | Compressible(_, inner) => Reply.writer(inner)
			Text(_) | Json(_) | Bytes(_, _) | Empty | StatusOnly(_) | Full(_) | Err(_) | File(_, _) => Err(NotStreamed)
		}

	## The file at `path` under `root`, opened by the platform after the
	## middleware: 200 with its bytes and a `content-type` from its extension,
	## or 404 when there is no such file under the root. A path out of the
	## root, through `..` or a symbolic link, is 404 too. Headers added with
	## `with_headers` are sent with it, and a `content-type` added there wins.
	file : FileRoot, Str -> Reply
	file = |root, path| Reply.(File(root, path))

	## Marks `reply` for `Compression.layer`. Platform code only.
	compressible = |reply, options| Reply.(Compressible(options, reply))

	## The options of the innermost `Compression.layer` the reply went
	## through, looking through wrappers. Platform code only.
	compression : Reply -> Try({ above_bytes : U64 }, [NotCompressible])
	compression = |reply|
		match reply {
			Compressible(options, inner) =>
				match Reply.compression(inner) {
					Ok(nearer) => Ok(nearer)
					Err(NotCompressible) => Ok(options)
				}
			WithStatus(_, inner) | WithHeaders(_, inner) | ReplaceHeaders(_, inner) | Routed(_, inner) => Reply.compression(inner)
			Text(_) | Json(_) | Bytes(_, _) | Empty | StatusOnly(_) | Full(_) | Err(_) | Writes(_, _) | File(_, _) => Err(NotCompressible)
		}

	## The file of a reply from `file`, looking through wrappers. Platform
	## code only.
	file_target : Reply -> Try({ root : FileRoot, path : Str }, [NotFile])
	file_target = |reply|
		match reply {
			File(root, path) => Ok({ root, path })
			WithStatus(_, inner) | WithHeaders(_, inner) | ReplaceHeaders(_, inner) | Routed(_, inner) | Compressible(_, inner) => Reply.file_target(inner)
			Text(_) | Json(_) | Bytes(_, _) | Empty | StatusOnly(_) | Full(_) | Err(_) | Writes(_, _) => Err(NotFile)
		}
	## For a field typed `[Ok(_), Err(Reply)]` in `Handler.typed`: the reply that
	## the failed field would have answered with.
	parser_for : _encoding -> (state -> Try({ value : Reply, rest : state }, _err)) where [state.rejection : state -> Reply]
	parser_for = |_encoding| |state| Ok({ value: state.rejection(), rest: state })

	## A 200 response with the string as body and
	## `content-type: text/plain; charset=utf-8`.
	text = |value| Reply.(Text(value))
	## A 200 response with `value` encoded as JSON and `content-type: application/json`.
	## A record or a list encodes as it is; a nominal type declares `encoder_for : _`.
	## A `Str` becomes a JSON string, so JSON that is already encoded goes through
	## `bytes`: `Reply.bytes(text.to_utf8(), "application/json")`.
	json : a -> Reply where [a.Json.Encodable([])]
	json = |value| Reply.(Json(Json.to_str(value)))
	## A 200 response with the bytes as body and the `Content-Type` `media_type`,
	## which a string literal gives, checked at compile time:
	## `Reply.bytes(pdf, "application/pdf")`. Use `application/octet-stream` for
	## bytes of no known type.
	bytes : List(U8), MediaType -> Reply
	bytes = |value, media_type| Reply.(Bytes(value, media_type))

	## Adds `Content-Disposition: attachment` to any reply, so a browser saves it,
	## replacing an existing field and keeping its status, type, and body. `filename`
	## is a suggested name: nonempty, not `.` or `..`, with no ASCII control, `/`, or
	## `\\`. A name beyond ASCII is sent as RFC 8187 `filename*`, with a plain fallback.
	attachment : Reply, Str -> Try(Reply, [InvalidFilename])
	attachment = |reply, filename| {
		value = ContentDisposition.attachment(filename)?
		Ok(Reply.replace_headers(reply, [Http.ResponseHeader.{ name: Http.HeaderName.("content-disposition"), value }]))
	}

	## A JSON Lines body (`application/x-ndjson`), written as it goes: `write!` gets
	## a `JsonLines` and sends each value encoded as JSON.
	##
	## ```roc
	## Reply.json_lines(|lines| {
	##     for order in orders {
	##         JsonLines.write!(lines, order)?
	##     }
	##     Ok({})
	## })
	## ```
	json_lines : (JsonLines => Try({}, [StreamClosed])) -> Reply
	json_lines = |write!| {
		value : HeaderValue
		value = "application/x-ndjson"
		Reply.stream(|target| write!(JsonLines.from_writer(target)))
			.replace_headers([Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value }])
	}
	## A 200 response with no body and no headers.
	empty = Reply.(Empty)
	## A response with the given status, no body, and no headers.
	status = |value| Reply.(StatusOnly(value))
	## Replaces the status of `reply`. Headers and body are kept.
	with_status = |reply, status_value| Reply.(WithStatus(status_value, reply))
	## Adds `headers` after the headers of `reply`. Existing headers, including
	## `content-type`, are not replaced or removed, so adding a second
	## `content-type` sends both.
	with_headers = |reply, headers| Reply.(WithHeaders(headers, reply))
	## Sets `headers` on `reply`, first removing any header of `reply` with the
	## same name (compared without regard to ASCII case). Use it for fields
	## that must appear once, such as `access-control-allow-origin` or
	## `x-request-id`, when a handler or inner layer may already have set them.
	replace_headers = |reply, headers| Reply.(ReplaceHeaders(headers, reply))
	## Sends `response` exactly as given.
	full = |response| Reply.(Full(response))
	## A plain-text response with the error's status and message. See
	## `HttpError`.
	error = |value| Reply.(Err(value))
	## Marks `reply` as the response of the route pattern `route`, such as
	## `/users/{id}`. The router marks the replies of matched routes, and the
	## host's access log names the route. Wrappers added later keep the mark.
	## The response is unchanged.
	with_route = |reply, route| Reply.(Routed(route, reply))
	## The route pattern the reply was marked with, looking through wrappers.
	## The outermost mark wins.
	route : Reply -> Try(Str, [Unrouted])
	route = |reply|
		match reply {
			Routed(value, _) => Ok(value)
			WithStatus(_, inner) | WithHeaders(_, inner) | ReplaceHeaders(_, inner) | Compressible(_, inner) => Reply.route(inner)
			Text(_) | Json(_) | Bytes(_, _) | Empty | StatusOnly(_) | Full(_) | Err(_) | Writes(_, _) | File(_, _) => Err(Unrouted)
		}
	## The status the reply's response will have, without building the
	## response (and copying its body). Wrappers apply from the inside out, as
	## in `Respond.to_response`.
	status_code : Reply -> U16
	status_code = |reply|
		match reply {
			# A file's 404 is decided only when the platform opens it.
			Text(_) | Json(_) | Bytes(_, _) | Empty | Writes(_, _) | File(_, _) => 200
			StatusOnly(value) | WithStatus(value, _) => Status.code(value)
			WithHeaders(_, inner) | ReplaceHeaders(_, inner) | Routed(_, inner) | Compressible(_, inner) => Reply.status_code(inner)
			Full(response) => response.status
			Err(http_error) => Status.code(HttpError.status(http_error))
		}
}

expect Reply.status_code(Reply.text("x")) == 200
expect Reply.status_code(Reply.status(204)) == 204
expect Reply.status_code(Reply.with_headers(Reply.with_status(Reply.text("x"), 201), [])) == 201
expect Reply.status_code(Reply.error(HttpError.not_found("missing"))) == 404
expect Reply.status_code(Reply.replace_headers(Reply.status(202), [])) == 202
expect Reply.status_code(Reply.with_route(Reply.status(404), "/users/{id}")) == 404

# The mark survives later wrappers; an unmarked reply has none.
expect Reply.route(Reply.text("x")) == Err(Unrouted)
expect Reply.route(Reply.with_route(Reply.text("x"), "/a")) == Ok("/a")
expect Reply.route(Reply.with_headers(Reply.with_status(Reply.with_route(Reply.text("x"), "/a"), 201), [])) == Ok("/a")
expect Reply.route(Reply.with_route(Reply.with_route(Reply.text("x"), "/inner"), "/outer")) == Ok("/outer")
