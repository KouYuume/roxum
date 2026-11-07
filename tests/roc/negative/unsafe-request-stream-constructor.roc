app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.RequestStream
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.Server

Model := {}
bad_segment = RequestStream.(1)
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| {
	_ = bad_segment.read!(1)
	Ok({ model: {}, listen: { address: Server.Ipv4Address.(127, 0, 0, 1), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
}
