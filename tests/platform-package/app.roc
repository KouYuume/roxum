app [program] {
	pf: platform "../../platform/main.roc",
	integration: "./integration/main.roc",
}

import integration.RoxumIntegration
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = {
	init!,
	routes: Router.build(routes, {}),
}

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
routes = Router.new
	.route("/", MethodRouter.get(Handler.effectful(handle!)))

handle! : Model, RouteContext({}) => Try(Reply, Reply)
handle! = |_model, _context| {
	response = Response.{
		status: 200,
		headers: [],
		body: ResponseBody.Bytes("ok".to_utf8()),
	}
	marked = RoxumIntegration.mark(response)
	logged = RoxumIntegration.log_response!(marked)
	Ok(Reply.full(logged))
}
