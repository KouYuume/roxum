app [program] {
	pf: platform "../../platform/main.roc",
	rate_limit: "../../integrations/roxum-rate-limit/package/main.roc",
}

import AppState
import Handlers
import Layers
import Provided
import Tag
import pf.Handler
import pf.MethodRouter
import pf.Router
import pf.IpAddr
import pf.Server
import rate_limit.RateLimit

Model : AppState

program = { init!, routes: Router.build(routes, Provided.{}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}|
	Ok({
		model: AppState.new!({})?,
		listen: {
			address: IpAddr.V4((127, 0, 0, 1)),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

## Each route says what it needs with tags; the layers below act on them.
routes : Router(Model, Tag, Provided)
routes =
	Router.new
		.route(
			"/notes",
			MethodRouter.methods([
				MethodRouter.get(Handler.stateful(Handlers.list_shared)),
				MethodRouter.post(Handler.typed(Handlers.create!)).tags([Tag.MembersOnly, Tag.Limit(5)]),
			]),
		)
		.route("/notes/mine", MethodRouter.get(Handler.typed(Handlers.list_mine!)).tags([Tag.MembersOnly]))
		.route("/notes/{id}", MethodRouter.delete(Handler.typed(Handlers.remove!)).tags([Tag.AdminOnly]))
		# Within a stage, the layer written first runs first, and is outermost:
		# `no_store` also sees the 401, 403, and 429 replies the layers after it make.
		.layer(Layers.no_store)
		.layer(Layers.authenticate)
		.layer(RateLimit.layer(Layers.post_limit))
