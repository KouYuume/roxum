app [program] { pf: platform "../../platform/main.roc" }

import pf.Concurrency
import pf.Tcp
import pf.Sleep
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.Server
import pf.IpAddr
import pf.Version

Model := { number : U64, limiter : Concurrency }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	limiter = match Concurrency.new!({ max_keys: 1 }) {
		Ok(value) => value
		Err(_) => return Err(StartupErr("limiter initialization failed"))
	}
	Ok({
		model: Model.({ number: 42, limiter }),
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes = {
	handler = Handler.effectful(wait_and_answer!)
	methods = MethodRouter.methods([MethodRouter.get(handler), MethodRouter.post(handler)])
	Router.new.route("/echo", methods).route("/reject", methods).route("/invalid-response", methods).route("/sleep", methods).route("/cancel", methods).route("/permit", methods).route("/tcp", methods).route("/tcp-cancel", methods)
}

wait_and_answer! = |Model.(state), context| {
	if context.request.path == "/cancel" or context.request.path == "/permit" or context.request.path == "/tcp-cancel" {
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
	if context.request.path == "/tcp" or context.request.path == "/tcp-cancel" {
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
		if context.request.path == "/tcp-cancel" {
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
	if request.path == "/invalid-response" {
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
