app [program] { pf: platform "../../platform/main.roc" }

import pf.HeaderName
import pf.HeaderValue
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}|
	Ok({
		model: {},
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes = Router.layer(Router.new, marker_layer)

marker_layer = {
	value : HeaderValue
	value = "default"
	header = ResponseHeader.{ name: HeaderName.("x-middleware"), value }
	[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [header]))]
}
