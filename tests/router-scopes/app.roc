app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.Router
import pf.Server

## M24 phase 3: what a layer covers, nested and merged routers, and checks
## before routing. The router has no fallback of its own.
Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}|
	Ok({
		model: {},
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/before", MethodRouter.get(ok))
		.nest("/admin", admin)
		.nest("/api", api)
		.nest("/tenants/{tenant}", tenant)
		.merge(right)
		.merge(shared_get)
		.merge(shared_delete)
		.layer(tag("root"))
		# Written after the layer, so not inside it.
		.route("/after", MethodRouter.get(ok))
		.before_routing(blocked_or_trimmed)

## A child's layer covers its routes and their 405 and 400, and no other path
## under its prefix.
admin =
	Router.new
		.route("/users/{id}", MethodRouter.get(ok))
		.layer(tag("admin"))

## A child with a fallback answers for the rest of its prefix, inside its layer.
api =
	Router.new
		.route("/items/{id}", MethodRouter.get(ok))
		.fallback(child_answer("api"))
		.layer(tag("api"))

tenant =
	Router.new
		.route("/home", MethodRouter.get(ok))
		.fallback(child_answer("tenant"))

right =
	Router.new
		.route("/right", MethodRouter.get(ok))
		.layer(tag("right"))

## Two routers share a path: each method keeps its own layer, and a 405 for the
## path belongs to neither.
shared_get =
	Router.new
		.route("/shared", MethodRouter.get(ok))
		.layer(tag("shared-get"))

shared_delete =
	Router.new
		.route("/shared", MethodRouter.delete(ok))
		.layer(tag("shared-delete"))

ok = Handler.static(|{}| Reply.text("ok"))

child_answer = |name| |reason, _model, _head| {
	label = name
	match reason {
		Router.Unmatched.NotFound => Ok(Reply.text("${label} not found").with_status(404))
		Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.text("${label} no method").with_status(405))
		Router.Unmatched.BadPath => Ok(Reply.text("${label} bad path").with_status(400))
	}
}

blocked_or_trimmed = |_model, head|
	if head.path == "/blocked" {
		Err(Reply.status(403))
	} else if head.path == "/before/" {
		Ok({ ..head, path: "/before" })
	} else {
		Ok(head)
	}

tag = |name| {
	text : Str
	text = name
	value = match HeaderValue.from_str(text) {
		Ok(header_value) => header_value
		Err(_) => crash "scope test marker contains a line break"
	}
	[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("x-stage"), value }]))]
}
