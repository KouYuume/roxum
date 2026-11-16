app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.RouteContext
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
routes = {
	# Layers are written outermost first.
	route_layers = |methods|
		methods
		.layer(marker_layer("route-outer"))
		.layer(marker_layer("route-inner"))

	nested = Router.new
		.route(
			"/nested",
			MethodRouter.get(Handler.pure(path_reply))
				.layer(marker_layer("nested")),
		)
	merged = Router.new
		.route(
			"/merged",
			MethodRouter.get(Handler.pure(path_reply))
				.layer(marker_layer("merged")),
		)

	Router.new
		.route(
			"/method/{id}",
			route_layers(MethodRouter.get(Handler.pure(path_reply))),
		)
		.route(
			"/head",
			MethodRouter.methods([
				MethodRouter.get(Handler.pure(path_reply))
					.layer(marker_layer("get")),
				MethodRouter.head(Handler.static(|{}| Reply.bytes("head".to_utf8(), "application/octet-stream")))
					.layer(marker_layer("head")),
			]),
		)
		.route(
			"/error",
			route_layers(MethodRouter.get(Handler.pure(error_reply))),
		)
		.nest("/api", nested)
		.merge(merged)
		.fallback(
			|reason, _model, _head|
				match reason {
					Router.Unmatched.NotFound => Ok(Reply.bytes("fallback".to_utf8(), "application/octet-stream"))
					Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.status(405))
					Router.Unmatched.BadPath => Ok(Reply.status(400))
				},
		)
		.layer(marker_layer("router-outer"))
		.layer(marker_layer("router-inner"))
}

marker_layer = |marker| {
	marker_text : Str
	marker_text = marker
	value = match HeaderValue.from_str(marker_text) {
		Ok(header_value) => header_value
		Err(_) => crash "test middleware marker contains a line break"
	}
	header = ResponseHeader.{ name: HeaderName.("x-middleware"), value }
	[
		Middleware.Stage.BeforeBody(|_model, head| Ok({ ..head, path: "${marker_text}:${head.path}" })),
		Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [header])),
	]
}

path_reply : RouteContext({}) -> Try(Reply, Reply)
path_reply = |context| Ok(Reply.bytes(context.request.path.to_utf8(), "application/octet-stream"))

error_reply : RouteContext({}) -> Try(Reply, Reply)
error_reply = |_context| Err(Reply.bytes("error".to_utf8(), "application/octet-stream").with_status(418))
