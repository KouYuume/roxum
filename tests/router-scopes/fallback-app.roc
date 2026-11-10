app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.Router
import pf.IpAddr
import pf.Server

## M24 phase 3: a root fallback stands where it is written.
Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}|
	Ok({
		model: {},
		listen: {
			address: IpAddr.V4((127, 0, 0, 1)),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/items/{id}", MethodRouter.get(Handler.static(|{}| Reply.text("ok"))))
		.layer(tag("first"))
		.fallback(
			|reason, _model, _head|
				match reason {
					Router.Unmatched.NotFound => Ok(Reply.text("not found").with_status(404))
					# Leaves out Allow, which the router adds.
					Router.Unmatched.MethodNotAllowed(methods) => Ok(Reply.text("methods ${methods.len().to_str()}").with_status(405))
					Router.Unmatched.BadPath => Err(Reply.text("bad path").with_status(400))
				},
		)
		.layer(tag("second"))

tag = |name| {
	text : Str
	text = name
	value = match HeaderValue.from_str(text) {
		Ok(header_value) => header_value
		Err(_) => crash "scope test marker contains a line break"
	}
	[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("x-stage"), value }]))]
}
