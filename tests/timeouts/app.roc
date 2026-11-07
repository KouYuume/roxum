app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

# Distinct first-request, keep-alive, body, and write limits show that each
# field reaches the host separately.
init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: Server.Ipv4Address.(127, 0, 0, 1),
		port: 0,
		timeouts: {
			..Server.Timeouts.defaults,
			initial_request_milliseconds: 1_000,
			keep_alive_idle_milliseconds: 3_000,
			request_body_milliseconds: 1_000,
			response_write_milliseconds: 5_000,
		},
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream"))))
		.route("/body", MethodRouter.post(Handler.static(|{}| Reply.bytes("ok".to_utf8(), "application/octet-stream"))))
		.route("/stream", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_chunks!(writer, 64)))))

# 64 chunks of 64 KiB, so a slow reader takes longer than the write limit.
# The limit leaves room for a loaded CI runner, where writing one chunk to a
# reader that keeps up has taken more than a second.
write_chunks! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_chunks! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, List.repeat('x', 64 * 1024))?
		write_chunks!(writer, remaining - 1)
	}
