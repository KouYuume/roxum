app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.PathSegment
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
bad_segment : PathSegment
bad_segment = "."
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| {
	_ = PathSegment.inner(bad_segment)
	Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
}
