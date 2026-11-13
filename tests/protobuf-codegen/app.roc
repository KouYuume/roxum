app [program] { generated: "generated/main.roc", pf: platform "../../platform/main.roc", proto: "../../libraries/roc-protobuf/package/main.roc" }

import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Router
import pf.Server
import proto.ProtobufWire
import generated.Packet
import generated.Empty

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		threads: Server.Threads.Fixed(1),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = Router.new.route("/copy", MethodRouter.post(Handler.stateful(answer))).route("/construct", MethodRouter.post(Handler.stateful(answer))).route("/defaults", MethodRouter.post(Handler.stateful(answer))).route("/view", MethodRouter.post(Handler.stateful(answer))).route("/empty", MethodRouter.post(Handler.stateful(answer))).route("/limits", MethodRouter.post(Handler.stateful(answer)))

answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 8, tags: 128, entries: 0, materialized_bytes: 512 }
	if context.request.path == "/view" {
		return match Packet.decode(bytes, limits) {
			Ok(Packet.(value)) => Ok(Reply.text("${value.count.to_str()},${value.code.to_str()},${value.stamp.to_str()},${value.payload.len().to_str()}"))
			Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
		}
	}
	result = if context.request.path == "/construct" {
		Packet.encode(Packet.{ count: 18446744073709551615, code: 4294967295, stamp: 9223372036854775808, payload: [0, 127, 128, 255] }, 4096)
	} else if context.request.path == "/defaults" {
		Packet.encode(Packet.defaults, 0)
	} else if context.request.path == "/empty" {
		copy_empty(bytes, limits)
	} else {
		copy_packet(
			bytes,
			limits,
			if context.request.path == "/limits" {
				16
			} else {
				4096
			},
		)
	}
	match result {
		Ok(value) => Ok(Reply.bytes(value, "application/octet-stream"))
		Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
}

copy_empty = |bytes, limits| {
	value = Empty.decode(bytes, limits)?
	Empty.encode(value, 4096)
}

copy_packet = |bytes, limits, max_bytes| {
	value = Packet.decode(bytes, limits)?
	Packet.encode(value, max_bytes)
}
