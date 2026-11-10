app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.HeaderValue
import pf.HeaderName
import pf.ResponseHeader
import pf.Log
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: IpAddr.V4((127, 0, 0, 1)),
		port: 0,
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
		request_id: Server.RequestIdSource.TrustIncoming,
	},
})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/dbg", MethodRouter.get(Handler.pure(traced)))
		.route("/many", MethodRouter.get(Handler.pure(many)))
		.route("/stream", MethodRouter.get(Handler.pure(streamed)))
		.route("/crash", MethodRouter.get(Handler.pure(crashing)))
		.route("/overflow", MethodRouter.get(Handler.pure(overflowing)))
		.route("/log", MethodRouter.get(Handler.effectful(logged!)))
		.route("/big-head", MethodRouter.get(Handler.pure(big_head)))

# Two values: plain text, and text that needs percent-encoding in a field.
traced : RouteContext({}) -> Try(Reply, Reply)
traced = |_context| {
	label = "loaded user"
	dbg label
	detail = "line1\nline2 é"
	dbg detail
	Ok(Reply.text("ok\n"))
}

# More values than the response carries.
many : RouteContext({}) -> Try(Reply, Reply)
many = |_context| {
	count = trace_countdown(20)
	Ok(Reply.text("${count.to_str()}\n"))
}

trace_countdown : U64 -> U64
trace_countdown = |remaining| {
	dbg remaining
	if remaining == 0 { 0 } else { trace_countdown(remaining - 1) + 1 }
}

# The handler's value reaches the head; the writer's only reaches the log.
streamed : RouteContext({}) -> Try(Reply, Reply)
streamed = |_context| {
	phase = "handler"
	dbg phase
	Ok(Reply.stream(write_chunk!))
}

write_chunk! : ResponseWriter => Try({}, [StreamClosed])
write_chunk! = |writer| {
	phase = "writer"
	dbg phase
	ResponseWriter.write!(writer, "chunk".to_utf8())
}

crashing : RouteContext({}) -> Try(Reply, Reply)
crashing = |_context| crash "debug test crash"

# Deeper than the fiber stack holds in every backend: speed takes
# about 16 bytes a level, so 64 MiB runs out after about 4 million.
overflowing : RouteContext({}) -> Try(Reply, Reply)
overflowing = |_context| Ok(Reply.text("${deeper(100_000_000).to_str()}\n"))

deeper : U64 -> U64
deeper = |remaining| if remaining == 0 { 0 } else { 1 + deeper(remaining - 1) }

# A message cannot start a log line of its own.
logged! : Model, RouteContext({}) => Try(Reply, Reply)
logged! = |_model, _context| {
	Log.info!("first\n[ERROR] forged")
	Ok(Reply.text("ok\n"))
}

# The application's own field leaves the head nearly full. The dbg fields
# give way, and are counted, instead of turning the response into a 500.
big_head : RouteContext({}) -> Try(Reply, Reply)
big_head = |_context| {
	count = trace_countdown(20)
	match HeaderValue.from_str(Str.repeat("a", 32_500)) {
		Ok(value) =>
			Ok(Reply.text("${count.to_str()}\n").with_headers([ResponseHeader.{ name: HeaderName.("x-fill"), value }]))
		Err(_) => Err(Reply.status(500))
	}
}
