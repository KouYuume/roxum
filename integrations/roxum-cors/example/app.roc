app [program] {
	cors: "../package/main.roc",
	pf: platform "../../../platform/main.roc",
}

import pf.Handler
import pf.HeaderValue
import pf.HeaderName
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.ResponseHeader
import pf.Router
import pf.Server
import cors.Cors

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
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
		.route(
			"/items",
			MethodRouter.methods([
				MethodRouter.get(Handler.static(|{}| Reply.bytes("items".to_utf8(), "application/octet-stream"))),
				MethodRouter.post(Handler.static(|{}| Reply.bytes("created".to_utf8(), "application/octet-stream"))),
			]),
		)
		.route("/inner", MethodRouter.get(Handler.static(|{}| inner_reply(Reply.bytes("inner".to_utf8(), "application/octet-stream")))))
		.route("/error", MethodRouter.get(Handler.pure(error_reply)))
		.layer(
			Cors.layer({
				..Cors.defaults,
				origins: Exact(["https://app.example"]),
				methods: [GET, POST],
				headers: [HeaderName.("content-type"), HeaderName.("x-token")],
				expose_headers: [HeaderName.("x-request-id")],
				credentials: Bool.True,
				max_age_seconds: Value(600),
			}),
		)

error_reply : RouteContext({}) -> Try(Reply, Reply)
error_reply = |_context| Err(inner_reply(Reply.bytes("error".to_utf8(), "application/octet-stream").with_status(418)))

# The outer policy must override grants on both successful and error replies.
inner_reply : Reply -> Reply
inner_reply = |reply| {
	origin : HeaderValue
	origin = "https://evil.example"
	credentials : HeaderValue
	credentials = "true"
	reply
		.with_headers([
			ResponseHeader.{ name: HeaderName.("Access-Control-Allow-Origin"), value: origin },
			ResponseHeader.{ name: HeaderName.("Access-Control-Allow-Credentials"), value: credentials },
		])
}
