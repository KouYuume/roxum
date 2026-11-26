app [program] {
	pf: platform "../../platform/main.roc",
	sse: "../../integrations/roxum-sse/package/main.roc",
}

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Server
import pf.Tcp
import sse.Sse

Model := { broker : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { broker_port : U16, http2 : Bool }
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	broker = Tcp.pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.broker_port, maximum_connections: 2 }).map_err(|_| StartupErr("broker pool"))?
	Ok({
		model: { broker },
		listen: Server.ListenOptions.{
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			protocol: if settings.http2 {
				Server.Protocol.Http2
			} else {
				Server.Protocol.Http1
			},
			threads: Server.Threads.Fixed(1),
			limits: Server.Limits.defaults,
			timeouts: Server.Timeouts.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route("/events", MethodRouter.get(Handler.stateful(subscribe)))
	.route("/publish", MethodRouter.post(Handler.effectful(publish!)))

subscribe : Model, RouteContext({}) -> Try(Reply, Reply)
subscribe = |model, _context|
	Ok(
		Sse.reply(
			|writer| Tcp.with!(
				model.broker,
				|connection| {
					Tcp.discard!(connection)
					Tcp.write!(connection, "S".to_utf8(), 5_000)?
					forward!(connection, writer)
				},
			).map_err(|_| StreamClosed),
		),
	)

forward! : Tcp.Connection, Sse.Writer => Try({}, _)
forward! = |connection, writer| {
	bytes = Tcp.read!(connection, 1, 60_000)?
	Sse.send!(writer, Sse.event(Str.from_utf8_lossy(bytes)))?
	forward!(connection, writer)
}

publish! : Model, RouteContext({}) => Try(Reply, Reply)
publish! = |model, context| {
	payload = match context.request.body {
		Bytes(bytes) => bytes
		_ => return Err(Reply.status(400))
	}
	match payload {
		[byte] if byte >= 65 and byte <= 90 => {
			count = Tcp.with!(
				model.broker,
				|connection| {
					Tcp.discard!(connection)
					Tcp.write!(connection, "P".to_utf8().concat([byte]), 5_000)?
					Tcp.read!(connection, 1, 5_000)
				},
			).map_err(|_| Reply.status(502))?
			Ok(Reply.bytes(count, "application/octet-stream"))
		}
		_ => Err(Reply.status(400))
	}
}
