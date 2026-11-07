app [program] { pf: platform "../../platform/main.roc" }

import pf.Request
import pf.QueryValue
import pf.PathSegment
import pf.RequestBody
import pf.Response
import pf.ResponseBody
import pf.ResponseHeader
import pf.HeaderName
import pf.HeaderValue
import pf.Extract
import pf.ResponseWriter
import pf.Reply
import pf.Log
import pf.Handler
import pf.Method
import pf.MethodRouter
import pf.RouteContext
import pf.Router
import pf.Server
import pf.Time
import pf.BodyLimit
import pf.HttpError

Model := {}

Payload := { name : Str }.{
	parser_for : _
}

TypedHeaders : {
	content_length : U64,
	x_request_id : Str,
}

program = {
	init!,
	routes: Router.build(routes, {}),
}

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	Log.debug!("m4-debug")
	Log.info!("m4-info")
	Log.warn!("m4-warn")
	Log.error!("m4-error")

	now = Time.now!({})
	milliseconds = Time.Timestamp.to_unix_milliseconds(now)
	if milliseconds > 0 {
		Log.info!("m4-time-${milliseconds.to_str()}")
	} else {
		Log.error!("m4-time-invalid")
	}

	Ok({
		model: {},
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes = {
	handler = Handler.effectful(handle!)
	read = MethodRouter.get(handler)
	write = MethodRouter.post(handler)
	both = MethodRouter.methods([read, write])
	param_methods = MethodRouter.methods([
		MethodRouter.get(Handler.pure(path_param_response)),
		MethodRouter.post(Handler.pure(path_param_response)),
	])
	Router.new
		.route("/", read)
		.route("/empty", read)
		.route("/query-value", MethodRouter.get(Handler.pure(query_value_reply)))
		.route("/authority", MethodRouter.get(Handler.pure(authority_reply)))
		.route("/echo", both)
		.route("/stream", read)
		.route("/stream-empty", read)
		.route("/stream-large", read)
		# Answer before the body is received, or after its first part, so
		# the host is left with an unread body (a handler that takes its
		# body whole runs only after the router received it).
		.route("/unread", MethodRouter.post(unread))
		.route("/partial", MethodRouter.post(partial))
	# Register the parameter before the static path to exercise precedence.
		.route("/users/{id}", param_methods)
		.route("/users/me", MethodRouter.get(Handler.static(|{}| Reply.full(text_response("static")))))
		.route("/files/{*rest}", MethodRouter.get(Handler.pure(path_param_response)))
		.route("/extract/{id}", MethodRouter.post(Handler.effectful(extracted_reply!)))
		.route("/typed-headers", MethodRouter.get(Handler.effectful(typed_headers_reply!)))
		# Larger than a socket send buffer, so a client that does not read
		# leaves bytes for the event loop to finish writing.
		.route("/large", MethodRouter.get(Handler.static(|{}| Reply.bytes(large_body(List.repeat('x', 4 * 1024), 10), "application/octet-stream"))))
		# 64 KiB built with the app: fills a client's buffers with few
		# requests, so a slow backend has little to run.
		.route("/medium", MethodRouter.get(Handler.static(|{}| Reply.bytes(large_body(List.repeat('m', 4 * 1024), 4), "application/octet-stream"))))
		.route(
			"/methods",
			MethodRouter.methods([
				MethodRouter.delete(Handler.static(|{}| Reply.full(Response.{ status: 200, headers: [], body: ResponseBody.Empty }))),
				MethodRouter.get(Handler.static(|{}| Reply.full(Response.{ status: 200, headers: [], body: ResponseBody.Empty }))),
				MethodRouter.post(Handler.static(|{}| Reply.full(Response.{ status: 200, headers: [], body: ResponseBody.Empty }))),
			]),
		)
		.route(
			"/head",
			MethodRouter.methods([
				MethodRouter.get(Handler.static(|{}| Reply.full(text_response("get")))),
				MethodRouter.head(
					Handler.static(
						|{}| Reply.full(
							Response.{
								status: 200,
								headers: [ResponseHeader.{ name: HeaderName.("x-head"), value: "explicit" }],
								body: ResponseBody.Bytes("head".to_utf8()),
							},
						),
					),
				),
			]),
		)
		.route("*", MethodRouter.options(Handler.static(|{}| Reply.status(204))))
		.route("/upload", MethodRouter.post(upload))
		.route("/limited-upload", MethodRouter.post(upload).layer(BodyLimit.streamed(Server.BodyLimit.Bytes(65_536))))
		.route(
			"/limited-json",
			MethodRouter.post(
				Handler.effectful(
					|_model, context| {
						payload : Payload
						payload = Extract.run!(Extract.json({}), context)?
						Ok(Reply.text(payload.name))
					},
				),
			)
				.layer(BodyLimit.whole(1_024)),
		)
}

## Gets the body in parts and answers how many bytes it had, holding only
## the part being read.
upload : Handler(Model, [], {})
upload = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Ok(0),
	chunk!: |counted, bytes| Ok(counted + List.len(bytes)),
	done!: |_model, counted| Ok(Reply.text(counted.to_str())),
})

## Answers before any of the body is received.
unread : Handler(Model, [], {})
unread = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Err(Reply.full(text_response("unread"))),
	chunk!: |state, _bytes| Ok(state),
	done!: |_model, _state| Ok(Reply.full(text_response("unread"))),
})

## Answers after the first part of the body.
partial : Handler(Model, [], {})
partial = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Ok({}),
	chunk!: |_state, _bytes| Err(Reply.full(text_response("partial"))),
	done!: |_model, _state| Ok(Reply.full(text_response("partial"))),
})

text_response = |text| Response.{ status: 200, headers: [], body: ResponseBody.Bytes(text.to_utf8()) }

# Doubles the bytes `doublings` times. Building 4 MiB this way stays fast in
# the interpreter, where appending one byte at a time takes seconds.
large_body : List(U8), U64 -> List(U8)
large_body = |bytes, doublings|
	if doublings == 0 {
		bytes
	} else {
		large_body(List.concat(bytes, bytes), doublings - 1)
	}

extracted_reply! : Model, RouteContext({}) => Try(Reply, Reply)
extracted_reply! = |_model, context| {
	id = Extract.run!(Extract.path_param("id"), context)?
	query = Extract.run!(Extract.query_str, context)?
	payload : Payload
	payload = Extract.run!(Extract.json({}), context)?
	Ok(Reply.text("${id}|${query}|${payload.name}"))
}

typed_headers_reply! : Model, RouteContext({}) => Try(Reply, Reply)
typed_headers_reply! = |_model, context| {
	headers : TypedHeaders
	headers = Extract.run!(Extract.typed_headers({}), context)?
	Ok(Reply.text("${headers.content_length.to_str()}|${headers.x_request_id}"))
}

path_param_response = |context|
	match List.first(context.path_params) {
		Ok(param) => Ok(Reply.full(text_response(param.value)))
		Err(_) => Ok(Reply.status(500))
	}

handle! : Model, RouteContext({}) => Try(Reply, Reply)
handle! = |_model, context| {
	request = context.request
	if request.path == "/stream" {
		Ok(Reply.stream(|writer| write_numbered!(writer, 3)))
	} else if request.path == "/stream-empty" {
		Ok(Reply.stream(|_writer| Ok({})))
	} else if request.path == "/stream-large" {
		# 64 parts of 64 KiB: far more than socket buffers hold, for slow readers.
		Ok(Reply.stream(|writer| write_large!(writer, 64)))
	} else {
		Ok(Reply.full(Response.{ status: 200, headers: [], body: buffered_body(request) }))
	}
}

buffered_body : Request -> ResponseBody
buffered_body = |request|
	if request.method == Method.HEAD {
		# The host must retain this representation length but suppress wire content.
		ResponseBody.Bytes("abc".to_utf8())
	} else {
		match request.body {
			RequestBody.Empty => ResponseBody.Empty
			RequestBody.Bytes(bytes) => ResponseBody.Bytes(bytes)
			# The router received the body; a stream reaches only a handler
			# run outside a router.
			RequestBody.Stream(_) => ResponseBody.Empty
		}
	}

write_numbered! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_numbered! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, "chunk-${remaining.to_str()}".to_utf8())?
		write_numbered!(writer, remaining - 1)
	}

write_large! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_large! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, List.repeat('x', 64 * 1024))?
		write_large!(writer, remaining - 1)
	}

# Keep the literal route independent of direct from_quote calls: the old
# scalar representation could be miscompiled depending on reachable code.
query_value_reply = |context| {
	quoted : QueryValue
	quoted = "a b&c=d#e+f"
	dynamic = Str.from_utf8_lossy(context.request.query)
	interpolated : QueryValue
	interpolated = "${dynamic}"
	segment : PathSegment
	segment = "a b/c?d"
	Ok(Reply.text("${QueryValue.inner(quoted)}|${QueryValue.inner(interpolated)}|${PathSegment.inner(segment)}"))
}

authority_reply = |context| match Request.authority(context.request) {
	Ok(bytes) => Ok(Reply.text(Str.from_utf8_lossy(bytes)))
	Err(_) => Ok(Reply.status(400))
}
