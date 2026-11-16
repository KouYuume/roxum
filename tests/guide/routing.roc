app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server

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

# ANCHOR: routes
routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("home\n"))))
		.route(
			"/users/{id}",
			MethodRouter.methods([
				MethodRouter.get(Handler.pure(show_user)),
				MethodRouter.delete(Handler.pure(delete_user)),
			]),
		)
		.route("/users/me", MethodRouter.get(Handler.static(|{}| Reply.text("me\n"))))
		.route("/files/{*rest}", MethodRouter.get(Handler.pure(show_file)))
		.nest("/api", api)
		.fallback(
			|reason, _model, _head|
				match reason {
					Router.Unmatched.NotFound => Ok(Reply.text("nothing here\n").with_status(404))
					Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.status(405))
					Router.Unmatched.BadPath => Ok(Reply.status(400))
				},
		)

api : Router(Model, [], {})
api =
	Router.new
		.route("/health", MethodRouter.get(Handler.static(|{}| Reply.text("ok\n"))))
# ANCHOR_END: routes

# ANCHOR: params
show_user : RouteContext({}) -> Try(Reply, Reply)
show_user = |context| Ok(Reply.text("user ${param(context, "id")}\n"))

delete_user : RouteContext({}) -> Try(Reply, Reply)
delete_user = |context| Ok(Reply.text("deleted ${param(context, "id")}\n"))

show_file : RouteContext({}) -> Try(Reply, Reply)
show_file = |context| Ok(Reply.text("file ${param(context, "rest")}\n"))

param : RouteContext({}), Str -> Str
param = |context, name|
	match List.first(List.keep_if(context.path_params, |p| p.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
# ANCHOR_END: params
