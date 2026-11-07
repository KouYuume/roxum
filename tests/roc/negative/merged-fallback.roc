app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.empty)
right : Router(Model, [], {})
right = Router.route(Router.new, "/", MethodRouter.get(handler)).fallback(|_reason, _model, _head| Ok(Reply.empty))
routes : Router(Model, [], {})
routes = Router.merge(Router.new, right)
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: Server.Ipv4Address.(127, 0, 0, 1), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
