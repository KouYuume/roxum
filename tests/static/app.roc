app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: IpAddr.V4((127, 0, 0, 1)),
		port: 0,
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

# Top-level values are evaluated when the app is built. The verifier looks for
# the computed text in the executable. The results are longer than Roc's
# 23-byte inline strings, so the optimizer keeps them as data.
page : Str
page = render(200_000, "")

render : U64, Str -> Str
render = |remaining, acc|
	if remaining == 0 {
		"BAKED-${Str.count_utf8_bytes(acc).to_str()}-PAGE-${acc}"
	} else {
		render(remaining - 1, if remaining % 50_000 == 0 { Str.concat(acc, "xxxxxxxx") } else { acc })
	}

# A whole reply can be a constant too; each request still gets its own copy
# to own.
about : Reply
about = Reply.text(render(100_000, "yyyyyyyy"))

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.text(page))))
		.route("/about", MethodRouter.get(Handler.static(|{}| about)))
