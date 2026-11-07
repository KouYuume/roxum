app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.Server
import pf.Status

Model := {}
bad_status = Status.(999)
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: Server.Ipv4Address.(127, 0, 0, 1), port: Status.code(bad_status), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
