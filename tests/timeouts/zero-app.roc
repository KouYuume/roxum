app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

# A zero timeout is rejected at startup.
init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: Server.Ipv4Address.(127, 0, 0, 1),
		port: 0,
		timeouts: {
			..Server.Timeouts.defaults,
			keep_alive_idle_milliseconds: 0,
		},
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream"))))
