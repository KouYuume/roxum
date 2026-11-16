app [program] {
	pf: platform "../../../platform/main.roc",
	normalize_path: "../package/main.roc",
}

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import normalize_path.NormalizePath

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
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.bytes("root".to_utf8(), "application/octet-stream"))))
		.route("/users", MethodRouter.get(Handler.pure(target_reply)))
		.route("/users/{id}", MethodRouter.get(Handler.pure(target_reply)))
		.before_routing(NormalizePath.trim({}))

# Returns the path and query the handler received.
target_reply : RouteContext({}) -> Try(Reply, Reply)
target_reply = |context| {
	query = Str.from_utf8_lossy(context.request.query)
	Ok(Reply.bytes("${context.request.path}?${query}".to_utf8(), "application/octet-stream"))
}
