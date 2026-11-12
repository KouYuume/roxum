app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Concurrency
import pf.Tcp
import pf.Sleep
import pf.RequestExecution
import pf.BodyLimit
import pf.Middleware
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Response
import pf.ResponseHeader
import pf.HeaderName
import pf.ResponseBody
import pf.Router
import pf.Server
import pf.IpAddr
import pf.Version

Model := { number : U64, limiter : Concurrency }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	if RequestExecution.elapsed_nanoseconds!({}) != Err(Unavailable) or RequestExecution.limit_nanoseconds!(0) != Err(Unavailable) {
		return Err(StartupErr("execution controls must be unavailable in init"))
	}
	settings : { path : Str, execution_milliseconds : Try(U64, [Missing]), http1 : Try(Bool, [Missing]), body_bytes : Try(U64, [Missing]), body_milliseconds : Try(U64, [Missing]), write_milliseconds : Try(U64, [Missing]) }
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	limiter = match Concurrency.new!({ max_keys: 1 }) {
		Ok(value) => value
		Err(_) => return Err(StartupErr("limiter initialization failed"))
	}
	execution = match settings.execution_milliseconds {
		Ok(milliseconds) => Server.ExecutionLimit.Milliseconds(milliseconds)
		Err(Missing) => Server.ExecutionLimit.Unlimited
	}
	io_timeout = if settings.execution_milliseconds.is_ok() { 10_000 } else { 1_000 }
	Ok({
		model: Model.({ number: 42, limiter }),
		listen: {
			endpoint: if Str.is_empty(settings.path) { Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }) } else { Server.Endpoint.Unix({ path: settings.path }) },
			protocol: if settings.http1 ?? Bool.False { Server.Protocol.Http1 } else { Server.Protocol.Http2 },
			threads: Server.Threads.Fixed(2),
			timeouts: { ..Server.Timeouts.defaults, request_head_milliseconds: 1_000, request_body_milliseconds: settings.body_milliseconds ?? io_timeout, response_write_milliseconds: settings.write_milliseconds ?? io_timeout },
			limits: { maximum_body_bytes: settings.body_bytes ?? 1024, maximum_streamed_body_bytes: Server.BodyLimit.Bytes(4), http2_execution: execution },
			access_log: Server.AccessLog.JsonLines,
			request_id: Server.RequestIdSource.TrustIncoming,
		},
	})
}

routes : Router(Model, [], {})
routes = {
	handler = Handler.effectful(wait_and_answer!)
	methods = MethodRouter.methods([MethodRouter.get(handler), MethodRouter.post(handler)])
	Router.new.route("/trailers", methods).route("/empty-trailers", methods).route("/invalid-trailers", methods).route("/echo", methods).route("/reject", methods).route("/invalid-response", methods).route("/sleep", methods).route("/cancel", methods).route("/permit", methods).route("/tcp", methods).route("/tcp-cancel", methods).route("/id", methods).route("/debug", methods).route("/debug-many", methods).route("/crash", methods).route("/execution-elapsed", methods).route("/execution-zero", methods).route("/execution-stale", methods).route("/execution-limit", methods).route("/execution-cap", methods).route("/execution-unavailable", methods)
		.route("/metadata-reject", MethodRouter.post(handler).layer([Middleware.Stage.BeforeBody(|_model, _head| Err(Reply.status(403)))]))
		.route("/metadata-reject-body", MethodRouter.post(handler).layer([Middleware.Stage.BeforeBody(|_model, _head| Err(Reply.text("denied").with_status(403)))]))
		.route("/metadata-reject-trailers", MethodRouter.post(handler).layer([Middleware.Stage.BeforeBody(|_model, _head| Err(Reply.text("denied").with_status(403).with_trailers([ResponseHeader.{ name: HeaderName.("x-result"), value: "done" }])))]))
		.route("/metadata-limit", MethodRouter.post(handler).layer(BodyLimit.whole(4)))
		.route("/metadata-stream", MethodRouter.post(collect).layer(BodyLimit.streamed(Server.BodyLimit.Bytes(4))))
		.route("/metadata-stream-default", MethodRouter.post(collect))
		.route("/metadata-stream-chunks", MethodRouter.post(collect).layer(BodyLimit.streamed(Server.BodyLimit.Unlimited)))
		.route("/metadata-chunks", MethodRouter.post(handler).layer([Middleware.Stage.OnChunk(uppercase)]))
		.route("/metadata-wait", MethodRouter.post(handler).layer([Middleware.Stage.BeforeBody(metadata_wait!)]))
		.route("/metadata-deadline", MethodRouter.post(Handler.effectful(must_not_run!)).layer([Middleware.Stage.BeforeBody(metadata_wait!)]))
		.route("/metadata-zero", MethodRouter.post(Handler.effectful(must_not_run!)).layer([Middleware.Stage.BeforeBody(metadata_wait!)]))

}

metadata_wait! = |Model.(state), head| {
	if head.path == "/metadata-zero" {
		RequestExecution.limit_nanoseconds!(0).map_err(|_| Reply.status(500))?
		crash "expired metadata returned to middleware"
	}
	if head.path == "/metadata-deadline" {
		RequestExecution.limit_nanoseconds!(500_000_000).map_err(|_| Reply.status(500))?
	}
	Concurrency.acquire!(state.limiter, "cancel-key", 1).map_err(|_| Reply.status(429))?
	port = U16.from_str(Str.from_utf8_lossy(head.query)).map_err(|_| Reply.status(400))?
	Tcp.with_origin!(
		Tcp.Origin.{ host: "127.0.0.1", port, tls: Tcp.Tls.Off, reuse_idle: Bool.False },
		1_000,
		|connection| {
			Tcp.write!(connection, "ready".to_utf8(), 1_000)?
			Tcp.discard!(connection)
			Ok({})
		},
	).map_err(|_| Reply.status(500))?
	Ok(head)
}

must_not_run! = |_model, _context| {
	Sleep.millis!(1)
	crash "metadata deadline reached the body handler"
}

uppercase = Middleware.ChunkCheck.new(
	{},
	|state, bytes| Ok({ state, bytes: List.map(bytes, |byte| if byte == 'a' { 'A' } else { byte }) }),
	|_state| Ok({}),
)

collect : Handler(Model, [], {})
collect = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Ok([]),
	chunk!: |received, bytes| Ok(List.concat(received, bytes)),
	done!: |_model, received| Ok(Reply.text(Str.from_utf8_lossy(received))),
	abort!: |_received, _reason| {},
})

wait_and_answer! = |Model.(state), context| {
	path = context.request.path
	if path == "/execution-unavailable" {
		if RequestExecution.elapsed_nanoseconds!({}) == Err(Unavailable) and RequestExecution.limit_nanoseconds!(0) == Err(Unavailable) { return Ok(Reply.text("unavailable")) }
		return Err(Reply.status(500))
	}
	if path == "/execution-elapsed" {
		first = RequestExecution.elapsed_nanoseconds!({}).map_err(|_| Reply.status(500))?
		RequestExecution.limit_nanoseconds!(U64.highest).map_err(|_| Reply.status(500))?
		Sleep.millis!(2)
		second = RequestExecution.elapsed_nanoseconds!({}).map_err(|_| Reply.status(500))?
		if second < first { crash "elapsed time moved backwards after resumption" }
		return Ok(Reply.text(first.to_str()))
	}
	if path == "/execution-zero" or path == "/execution-stale" {
		elapsed = RequestExecution.elapsed_nanoseconds!({}).map_err(|_| Reply.status(500))?
		RequestExecution.limit_nanoseconds!(if path == "/execution-zero" { 0 } else { elapsed }).map_err(|_| Reply.status(500))?
		crash "expired execution returned to application code"
	}
	if path == "/execution-cap" {
		RequestExecution.limit_nanoseconds!(5_000_000_000).map_err(|_| Reply.status(500))?
		Sleep.millis!(60_000)
		crash "server cap was extended"
	}
	if path == "/execution-limit" {
		RequestExecution.limit_nanoseconds!(500_000_000).map_err(|_| Reply.status(500))?
		RequestExecution.limit_nanoseconds!(U64.highest).map_err(|_| Reply.status(500))?
	}
	if context.request.path == "/crash" { crash "HTTP/2 handler failure" }
	if context.request.path == "/debug" {
		label = "HTTP/2 debug"
		dbg label
		return Ok(Reply.text("debug"))
	}
	if context.request.path == "/debug-many" {
		count = debug_countdown(20)
		return Ok(Reply.text(count.to_str()))
	}
	if context.request.path == "/cancel" or context.request.path == "/permit" or context.request.path == "/tcp-cancel" or path == "/execution-limit" {
		match Concurrency.acquire!(state.limiter, "cancel-key", 1) {
			Ok({}) => {}
			Err(_) => return Ok(Reply.text("busy").with_status(429))
		}
	}
	if context.request.path == "/sleep" {
		Sleep.millis!(2)
		Sleep.millis!(2)
	}
	if context.request.path == "/cancel" {
		Sleep.millis!(60000)
		crash "cancelled handler resumed application code"
	}
	if context.request.path == "/tcp" or context.request.path == "/tcp-cancel" or path == "/execution-limit" {
		port = match context.request.body {
			RequestBody.Bytes(bytes) => U16.from_str(Str.from_utf8_lossy(bytes)) ?? 0
			_ => 0
		}
		result = Tcp.with_origin!(
			Tcp.Origin.{ host: "127.0.0.1", port, tls: Tcp.Tls.Off, reuse_idle: Bool.False },
			60_000,
			|connection| {
				bytes = Tcp.read!(connection, 1, 60_000)?
				Tcp.discard!(connection)
				Ok(Str.from_utf8_lossy(bytes))
			},
		)
		if context.request.path == "/tcp-cancel" or path == "/execution-limit" {
			crash "cancelled TCP handler resumed application code"
		}
		return Ok(Reply.text(match result {
			Ok(text) => text
			Err(_) => "tcp failed"
		}))
	}
	answer(state.number, context)
}

answer = |number, context| {
	request = context.request
	if request.path == "/trailers" or request.path == "/empty-trailers" or request.path == "/invalid-trailers" {
		body = if request.path == "/empty-trailers" { "" } else { "finite body" }
		name = if request.path == "/invalid-trailers" { "Content-Length" } else { "Grpc-Status" }
		Ok(Reply.text(body).with_trailers([ResponseHeader.{ name: HeaderName.(name), value: "0" }]))
	} else if request.path == "/id" {
		Ok(Reply.text(request.request_id))
	} else if request.path == "/invalid-response" {
		Ok(Reply.full(Response.{ status: 204, headers: [], body: ResponseBody.Bytes("invalid".to_utf8()) }))
	} else if request.path == "/reject" {
		Err(Reply.text("rejected by Roc").with_status(422))
	} else {
		version = match request.version {
			Version.Http20 => "h2"
			_ => "wrong-version"
		}
		body = match request.body {
			RequestBody.Bytes(bytes) => Str.from_utf8_lossy(bytes)
			RequestBody.Empty => ""
			RequestBody.Stream(_) => "unexpected-stream"
		}
		Ok(Reply.text("${number.to_str()}|${version}|${body}"))
	}
}

# Exceeds the capture limit without depending on allocator or backend timing.
debug_countdown : U64 -> U64
debug_countdown = |remaining| {
	dbg remaining
	if remaining == 0 { 0 } else { debug_countdown(remaining - 1) + 1 }
}
