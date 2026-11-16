app [program] { pf: platform "../../platform/main.roc", proto: "../../libraries/roc-protobuf/package/main.roc" }

import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Router
import pf.Server
import proto.ProtobufWire

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
routes = Router.new.route("/packed-varints", MethodRouter.post(Handler.stateful(packed_answer))).route("/packed-fixed32", MethodRouter.post(Handler.stateful(packed_answer))).route("/packed-fixed64", MethodRouter.post(Handler.stateful(packed_answer))).route("/copy", MethodRouter.post(Handler.stateful(answer))).route("/skip", MethodRouter.post(Handler.stateful(answer)))

answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	match scan(bytes, context.request.path == "/skip") {
		Ok(value) => Ok(Reply.bytes(value, "application/octet-stream"))
		Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
}

# Both paths walk the same input; copy checks primitives, skip checks discard.
scan : List(U8), Bool -> Try(List(U8), ProtobufWire.Error)
scan = |input, skip| {
	limits = { input_bytes: 4096, field_bytes: 256, depth: 8, tags: 128, entries: 64, materialized_bytes: 512 }
	var $reader = ProtobufWire.new_reader(input, limits)?
	var $writer = ProtobufWire.new_writer(4096)
	while ProtobufWire.remaining($reader) > 0 {
		(field, after_tag) = ProtobufWire.read_tag($reader)?
		if skip or field.kind == StartGroup or field.kind == EndGroup {
			$reader = ProtobufWire.skip(after_tag, field)?
		} else {
			$writer = ProtobufWire.write_tag($writer, field)?
			$reader = ProtobufWire.reserve(after_tag, 1, 0)?
			match field.kind {
				Varint => {
					(value, after) = ProtobufWire.read_varint($reader)?
					$reader = after
					$writer = ProtobufWire.write_varint($writer, value)?
				}
				Fixed64 => {
					(value, after) = ProtobufWire.read_fixed64($reader)?
					$reader = after
					$writer = ProtobufWire.write_fixed64($writer, value)?
				}
				Fixed32 => {
					(value, after) = ProtobufWire.read_fixed32($reader)?
					$reader = after
					$writer = ProtobufWire.write_fixed32($writer, value)?
				}
				Bytes => {
					(value, after) = ProtobufWire.read_bytes($reader)?
					$reader = after
					$writer = ProtobufWire.write_bytes($writer, value)?
				}
				_ => return Err(UnexpectedEndGroup)
			}
		}
	}
	Ok(ProtobufWire.output($writer))
}

packed_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	match packed_scan(bytes, context.request.path) {
		Ok(value) => Ok(Reply.bytes(value, "application/octet-stream"))
		Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
}

packed_scan = |input, path| {
	limits = { input_bytes: 4096, field_bytes: 256, depth: 0, tags: 0, entries: 64, materialized_bytes: 0 }
	var $reader = ProtobufWire.new_reader(input, limits)?
	var $writer = ProtobufWire.new_writer(4096)
	while ProtobufWire.remaining($reader) > 0 {
		if path == "/packed-fixed32" {
			(values, after) = ProtobufWire.read_packed_fixed32($reader)?
			$reader = after
			for value in values {
				$writer = ProtobufWire.write_fixed32($writer, value)?
			}
		} else if path == "/packed-fixed64" {
			(values, after) = ProtobufWire.read_packed_fixed64($reader)?
			$reader = after
			for value in values {
				$writer = ProtobufWire.write_fixed64($writer, value)?
			}
		} else {
			(values, after) = ProtobufWire.read_packed_varints($reader)?
			$reader = after
			for value in values {
				$writer = ProtobufWire.write_varint($writer, value)?
			}
		}
	}
	Ok(ProtobufWire.output($writer))
}
