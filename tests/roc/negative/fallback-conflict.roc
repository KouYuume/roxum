app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}
handler = Handler.static(|{}| Reply.status(404))
routes : Router(Model, [], {})
routes = Router.new
	.fallback(|_reason, _model, _head| Ok(Reply.empty))
	.fallback(|_reason, _model, _head| Ok(Reply.empty))
program = { init!, routes: Router.build(routes, {}) }
init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
