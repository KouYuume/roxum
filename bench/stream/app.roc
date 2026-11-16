app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.ResponseWriter
import pf.Router
import pf.IpAddr
import pf.Server

## Written bodies for bench/stream/run.py: many small parts, and fewer parts
## of 64 KiB.

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
		.route("/small", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_copies!(writer, List.repeat('s', 100), 10_000)))))
		.route("/large", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_copies!(writer, List.repeat('l', 64 * 1024), 256)))))

## `remaining` copies of `bytes`, one write each.
write_copies! : ResponseWriter, List(U8), U64 => Try({}, [StreamClosed])
write_copies! = |writer, bytes, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, bytes)?
		write_copies!(writer, bytes, remaining - 1)
	}
