app [program] { pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server
import pf.Tcp

Model := { upstream : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { upstream_port : U16, admin_port : U16 }
	settings = Config.load!("upstream_port = 1\nadmin_port = 1").map_err(|ConfigErr(message)| StartupErr(message))?
	pool = Tcp.pool!(Tcp.PoolOptions.{ host: "::1", port: settings.upstream_port }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { upstream: pool },
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V6((0, 0, 0, 0, 0, 0, 0, 0)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
			processes: 2,
			metrics: Server.Metrics.Listen(Server.Endpoint.Tcp({ address: IpAddr.V6((0, 0, 0, 0, 0, 0, 0, 1)), port: settings.admin_port })),
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route(
		"/",
		MethodRouter.get(
			Handler.stateful(
				|_model, context|
					Ok(
						Reply.text(
							match context.request.remote_addr {
								Tcp({ ip: V6((0, 0, 0, 0, 0, 0, 0, 1)), .. }) => "ipv6"
								_ => "unexpected peer"
							},
						),
					),
			),
		),
	)
	.route(
		"/outbound",
		MethodRouter.get(
			Handler.effectful(
				|model, _context| {
					result = Tcp.with!(
						model.upstream,
						|connection| {
							Tcp.write!(connection, "PING".to_utf8(), 1000)?
							var $bytes = []
							while $bytes.len() < 4 {
								chunk = Tcp.read!(connection, 4 - $bytes.len(), 1000)?
								if chunk.is_empty() {
									break
								}
								$bytes = $bytes.concat(chunk)
							}
							Ok($bytes)
						},
					)
					match result {
						Ok(bytes) => Ok(Reply.text(Str.from_utf8_lossy(bytes)))
						Err(_) => Err(Reply.status(502))
					}
				},
			),
		),
	)
