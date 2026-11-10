app [program] { pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { path : Str, metrics_path : Str }
	settings = Config.load!("path = '/tmp/roxum.sock'\nmetrics_path = '/tmp/roxum-metrics.sock'").map_err(|ConfigErr(message)| StartupErr(message))?
	Ok({
		model: {},
		listen: {
			endpoint: Server.Endpoint.Unix({ path: settings.path }),
			metrics: Server.Metrics.Listen(Server.Endpoint.Unix({ path: settings.metrics_path })),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
			processes: 2,
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.stateful(peer)))
	.route("/echo", MethodRouter.post(Handler.stateful(echo)))

peer : Model, RouteContext({}) -> Try(Reply, Reply)
peer = |_model, context| Ok(
	Reply.text(
		match context.request.remote_addr {
			Unix => "unix"
			Tcp(_) => "unexpected tcp"
		},
	),
)

echo : Model, RouteContext({}) -> Try(Reply, Reply)
echo = |_model, context| {
	bytes = match context.request.body {
		Bytes(body) => body
		Empty => []
		Stream(_) => []
	}
	Ok(Reply.bytes(bytes, "application/octet-stream"))
}
