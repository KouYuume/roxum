app [program] {
	pf: platform "../../../platform/main.roc",
	trace: "../package/main.roc",
}

import pf.Handler
import pf.HeaderName
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import trace.RequestId
import trace.Trace

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

# RequestId is added last, so it is the outer layer and sets the ID on
# every reply, including the ones Trace sees.
routes : Router(Model, [], {})
routes =
	Router.new
		.route("/ok", MethodRouter.get(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream"))))
		.route("/request-id", MethodRouter.get(Handler.pure(request_id_reply)))
		.route("/users/{id}", MethodRouter.get(Handler.pure(path_reply)))
		.route("/error", MethodRouter.get(Handler.pure(error_reply)))
		.layer(Trace.layer({}))
		.layer(RequestId.layer({}))

# Returns the request's ID, then every x-request-id field the handler
# received, comma-separated, on a second line.
request_id_reply : RouteContext({}) -> Try(Reply, Reply)
request_id_reply = |context| {
	values = List.map(
		List.keep_if(context.request.headers, |header| header.name == HeaderName.("x-request-id")),
		|header| Str.from_utf8_lossy(header.value),
	)
	Ok(Reply.bytes("${context.request.request_id}\n${Str.join_with(values, ",")}".to_utf8(), "application/octet-stream"))
}

path_reply : RouteContext({}) -> Try(Reply, Reply)
path_reply = |context| Ok(Reply.bytes(context.request.path.to_utf8(), "application/octet-stream"))

error_reply : RouteContext({}) -> Try(Reply, Reply)
error_reply = |_context| Err(Reply.bytes("error".to_utf8(), "application/octet-stream").with_status(418))
