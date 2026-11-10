app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.status(200))
routes : Router(Model, [], {})
routes = Router.new
    .route("/users/{id}", MethodRouter.get(handler))
    .route("/users/{name}", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { address: IpAddr.V4((127, 0, 0, 1)), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
