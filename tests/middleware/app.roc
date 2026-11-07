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
import pf.Server
import pf.Time

Model := { marker : Str }

program = {
	init!,
	routes: Router.build(routes, {}),
}

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}|
	Ok({
		model: { marker: "stateful" },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes = {
	# Written outermost first: outer sees the request first
	# and the reply last.
	layered = |methods|
		methods
		.layer(marker_layer("outer"))
		.layer(marker_layer("inner"))
	Router.new
		.route("/pure", layered(MethodRouter.get(Handler.pure(pure_handler))))
		.route("/stateful", layered(MethodRouter.get(Handler.stateful(stateful_handler))))
		.route("/effectful", layered(MethodRouter.get(Handler.effectful(effectful_handler!))))
		.route("/static", layered(MethodRouter.get(Handler.static(|{}| Reply.bytes("static".to_utf8(), "application/octet-stream")))))
		.route("/error", layered(MethodRouter.get(Handler.pure(error_handler))))
}

## Prefixes the path the handler sees before the body, and tags the reply on
## its way out: one layer with two stages.
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

pure_handler : RouteContext({}) -> Try(Reply, Reply)
pure_handler = |context| Ok(Reply.bytes(context.request.path.to_utf8(), "application/octet-stream"))

stateful_handler : Model, RouteContext({}) -> Try(Reply, Reply)
stateful_handler = |model, _context| Ok(Reply.bytes(model.marker.to_utf8(), "application/octet-stream"))

effectful_handler! : Model, RouteContext({}) => Try(Reply, Reply)
effectful_handler! = |_model, _context| {
	_ = Time.now!({})
	Ok(Reply.bytes("effectful".to_utf8(), "application/octet-stream"))
}

error_handler : RouteContext({}) -> Try(Reply, Reply)
error_handler = |_context| Err(Reply.bytes("error".to_utf8(), "application/octet-stream").with_status(418))
