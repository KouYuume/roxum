app [program] { pf: platform "../../platform/main.roc" }

import pf.Sleep
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Response
import pf.ResponseBody
import pf.Router
import pf.Server
import pf.IpAddr
import pf.Version

Model := U64

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: Model.(42),
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = {
	handler = Handler.effectful(wait_and_answer!)
	methods = MethodRouter.methods([MethodRouter.get(handler), MethodRouter.post(handler)])
	Router.new.route("/echo", methods).route("/reject", methods).route("/invalid-response", methods).route("/sleep", methods)
}

wait_and_answer! = |model, context| {
	if context.request.path == "/sleep" {
		Sleep.millis!(2)
		Sleep.millis!(2)
	}
	answer(model, context)
}

answer = |Model.(number), context| {
	request = context.request
	if request.path == "/invalid-response" {
		Ok(Reply.full(Response.{ status: 204, headers: [], body: ResponseBody.Bytes("invalid".to_utf8()) }))
	} else if request.path == "/reject" {
		Err(Reply.text("rejected by Roc").with_status(422))
	} else {
		version = match request.version {
			Version.Http20 => "h2"
			_ => "wrong-version"
		}
		body = match request.body {
			RequestBody.Bytes(bytes) => Str.from_utf8_lossy(bytes)
			RequestBody.Empty => ""
			RequestBody.Stream(_) => "unexpected-stream"
		}
		Ok(Reply.text("${number.to_str()}|${version}|${body}"))
	}
}
