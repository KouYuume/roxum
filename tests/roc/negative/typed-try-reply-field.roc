app [program] { pf: platform "../../../platform/main.roc" }

import pf.Handler
import pf.Extract
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

# Roc derives a Try only as an optional field; the field is [Ok(_), Err(Reply)].
create! : Model, { item : Try(Extract.Text, Reply) } => Try(Reply, Reply)
create! = |_model, _input| Ok(Reply.empty)

routes : Router(Model, [], {})
routes = Router.route(Router.new, "/", MethodRouter.post(Handler.typed(create!)))

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })
