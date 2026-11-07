app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/files/{*rest}/more", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: Server.Ipv4Address.(127, 0, 0, 1), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
