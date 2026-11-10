app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.HeaderValue
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
bad_header : HeaderValue
bad_header = "safe\r\ninjected: true"
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| {
	_ = HeaderValue.inner(bad_header)
	Ok({ model: {}, listen: { address: IpAddr.V4((127, 0, 0, 1)), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
}
