app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
# An F64 may be NaN or an infinity, which JSON cannot represent.
handler = Handler.static(|{}| Reply.json({ ratio: 0.5.F64 }))
routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.get(handler))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
