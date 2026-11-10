app [program] { pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import pf.Tcp

Model := { gate : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| {
	settings : { port : U16 }
	settings = Config.load!("port = 1").map_err(|_| StartupErr("config"))?
	gate = Tcp.pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.port }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { gate },
		listen: {
			address: IpAddr.V4((127, 0, 0, 1)),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: { maximum_streams: Server.Count.Fixed(1) },
			threads: Server.Threads.Fixed(1),
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route(
		"/wait",
		MethodRouter.get(
			Handler.effectful(
				|model, _context| {
					_ = Tcp.with!(
						model.gate,
						|connection| {
							bytes = Tcp.read!(connection, 1, 10_000)?
							Tcp.discard!(connection)
							Ok(bytes)
						},
					).map_err(|_| Reply.text("gate failed").with_status(500))?
					Ok(stream(1024))
				},
			),
		),
	)
	.route("/short", MethodRouter.get(Handler.static(|{}| stream(2))))
	.route("/gate-stream", MethodRouter.get(Handler.effectful(gate_stream!)))

## Writes, then waits for the gate inside the body: a client that
## goes meanwhile stops the handler there, and its gate connection closes.
gate_stream! : Model, RouteContext({}) => Try(Reply, Reply)
gate_stream! = |model, _context| Ok(
	Reply.stream(
		|writer| {
			ResponseWriter.write!(writer, "a".to_utf8())?
			_ = Tcp.with!(model.gate, |connection| Tcp.read!(connection, 1, 10_000))
			ResponseWriter.write!(writer, "b".to_utf8())
		},
	),
)

stream = |count| Reply.stream(|writer| write_chunks!(writer, count))

write_chunks! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_chunks! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, List.repeat('x', 64 * 1024))?
		write_chunks!(writer, remaining - 1)
	}
