app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.empty)
child : Router(Model, [], {})
child = Router.route(Router.new, "/", MethodRouter.get(handler)).before_routing(|_model, head| Ok(head))
routes : Router(Model, [], {})
routes = Router.nest(Router.new, "/api", child)
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: IpAddr.V4((127, 0, 0, 1)), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
