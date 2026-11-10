app [program] {
	pf: platform "../../platform/main.roc",
	sse: "../../integrations/roxum-sse/package/main.roc",
}

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import sse.Sse

## Server-sent events built at run time, for bench/stream/sse_memory.py: how
## much a stream keeps while its client reads slowly.

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
	},
})

routes : Router(Model, [], {})
routes = Router.new.route("/many", MethodRouter.get(Handler.pure(many)))

## 5000 events of about 90 bytes, each built from the request.
many : RouteContext({}) -> Try(Reply, Reply)
many = |context| {
	var $events = []
	var $index = 0
	while $index < 5000 {
		$events = List.append($events, Sse.event("event ${$index.to_str()} for ${context.request.path} with padding to make it longer"))
		$index = $index + 1
	}
	Ok(Sse.from_events($events))
}
