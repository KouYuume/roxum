app [program] {
	pf: platform "../../../platform/main.roc",
	set_header: "../package/main.roc",
}

import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import set_header.SetHeader

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = {
	route_layer = SetHeader.layer(HeaderName.("x-route"), header_value("route"))
	global_inner = SetHeader.layer(HeaderName.("x-global"), header_value("inner"))
	global_outer = SetHeader.layer(HeaderName.("x-global"), header_value("outer"))

	Router.new
		.route(
			"/ok",
			MethodRouter.get(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream")))
				.layer(route_layer),
		)
		.route(
			"/users/{id}",
			MethodRouter.get(Handler.pure(path_reply))
				.layer(route_layer),
		)
		.route(
			"/error",
			MethodRouter.get(Handler.pure(error_reply))
				.layer(route_layer),
		)
		# Written outermost first: the outer layer adds its
		# field last.
		.layer(global_outer)
		.layer(global_inner)
}

header_value = |value|
	match HeaderValue.from_str(value) {
		Ok(valid) => valid
		Err(_) => crash "static test header value is invalid"
	}

path_reply : RouteContext({}) -> Try(Reply, Reply)
path_reply = |context| Ok(Reply.bytes(context.request.path.to_utf8(), "application/octet-stream"))

error_reply : RouteContext({}) -> Try(Reply, Reply)
error_reply = |_context| Err(Reply.bytes("error".to_utf8(), "application/octet-stream").with_status(418))
