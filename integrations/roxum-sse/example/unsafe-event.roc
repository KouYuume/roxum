app [program] {
	pf: platform "../../../platform/main.roc",
	sse: "../package/main.roc",
}

import pf.Handler
import pf.MethodRouter
import pf.Router
import pf.Server
import sse.Sse

Model := {}
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: Server.Ipv4Address.(127, 0, 0, 1), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(Handler.pure(|_context| {
	event = Sse.Event.({
		data: "payload",
		event_type: Value("safe\ndata: injected\n\ndata: forged"),
		id: None,
		retry_milliseconds: None,
	})
	Ok(Sse.from_events([event]))
})))
