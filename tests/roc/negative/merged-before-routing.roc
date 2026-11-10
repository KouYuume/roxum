app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.empty)
right : Router(Model, [], {})
right = Router.route(Router.new, "/", MethodRouter.get(handler)).before_routing(|_model, head| Ok(head))
routes : Router(Model, [], {})
routes = Router.merge(Router.new, right)
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
