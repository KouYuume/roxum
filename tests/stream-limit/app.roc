app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server
import pf.Sleep

Model := {}

program = { init!, routes: Router.build(routes, {}) }

# One stream per worker process, so a second live stream in a process is
# answered 503.
init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: Server.Ipv4Address.(127, 0, 0, 1),
		port: 0,
		timeouts: Server.Timeouts.defaults,
		limits: { maximum_streams: Server.Count.Fixed(1) },
	},
})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream"))))
		.route("/long", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_chunks!(writer, 1024)))))
		.route("/short", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_chunks!(writer, 2)))))
		.route("/sleepy", MethodRouter.get(Handler.static(|{}| sleepy)))

## Writes, then sleeps 10 s inside the body with keep-alive bytes every
## 200 ms: the client sees them, and a client that goes stops the
## handler at its sleep, giving the stream's place back.
sleepy : Reply
sleepy = Reply.stream_with(
	ResponseWriter.Options.{ keep_alive: ResponseWriter.KeepAlive.Every({ milliseconds: 200, bytes: ":\n".to_utf8() }) },
	|writer| {
		ResponseWriter.write!(writer, "a".to_utf8())?
		Sleep.millis!(10_000)
		ResponseWriter.write!(writer, "b".to_utf8())
	},
)

# `remaining` chunks of 64 KiB. 1024 of them (64 MiB) stay live while the
# client does not read.
write_chunks! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_chunks! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, List.repeat('x', 64 * 1024))?
		write_chunks!(writer, remaining - 1)
	}
