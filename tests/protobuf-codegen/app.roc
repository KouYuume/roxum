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
import generated.Scalars
import generated.OptionalScalars
import generated.Envelope
import generated.EnvelopePayload
import generated.EnvelopeEmpty
import generated.Entry
import generated.EntryDetail

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
routes = Router.new.route("/identity-copy", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-view", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-construct", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-empty", MethodRouter.post(Handler.stateful(identity_answer))).route("/optional", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-view", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-text", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-bytes", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-construct", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-defaults", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-clear", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-limits", MethodRouter.post(Handler.stateful(optional_answer))).route("/scalars", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-view", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-text", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-construct", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-limits", MethodRouter.post(Handler.stateful(scalar_answer))).route("/copy", MethodRouter.post(Handler.stateful(answer))).route("/construct", MethodRouter.post(Handler.stateful(answer))).route("/defaults", MethodRouter.post(Handler.stateful(answer))).route("/view", MethodRouter.post(Handler.stateful(answer))).route("/empty", MethodRouter.post(Handler.stateful(answer))).route("/limits", MethodRouter.post(Handler.stateful(answer)))

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

scalar_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	if context.request.path == "/scalar-construct" {
		value = Scalars.{ unsigned32: 4294967295, signed32: -2147483648, signed64: -9223372036854775808, zigzag32: -2147483648, zigzag64: -9223372036854775808, signed_fixed32: -2147483648, signed_fixed64: -9223372036854775808, enabled: Bool.True, text: "Roc 🐦", float_value: F32.from_bits(0x80000000), double_value: F64.infinity }
		return scalar_reply(Scalars.encode(value, 4096))
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 8, tags: 128, entries: 0, materialized_bytes: 512 }
	value = match Scalars.decode(bytes, limits) {
		Ok(decoded) => decoded
		Err(error) => return Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
	Scalars.(record) = value
	if context.request.path == "/scalar-text" {
		return Ok(Reply.text(record.text))
	}
	if context.request.path == "/scalar-view" {
		enabled = if record.enabled {
			"1"
		} else {
			"0"
		}
		return Ok(Reply.text("${record.unsigned32.to_str()},${record.signed32.to_str()},${record.signed64.to_str()},${record.zigzag32.to_str()},${record.zigzag64.to_str()},${record.signed_fixed32.to_str()},${record.signed_fixed64.to_str()},${enabled},${record.float_value.to_bits().to_str()},${record.double_value.to_bits().to_str()}"))
	}
	match Scalars.encode(
		value,
		if context.request.path == "/scalar-limits" {
			16
		} else {
			4096
		},
	) {
		Ok(encoded) => Ok(Reply.bytes(encoded, "application/octet-stream"))
		Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
}

scalar_reply = |encoded| match encoded {
	Ok(bytes) => Ok(Reply.bytes(bytes, "application/octet-stream"))
	Err(error) => Ok(Reply.text(Str.inspect(error)).with_status(400))
}

optional_answer = |_model, context| {
	if context.request.path == "/optional-defaults" {
		return scalar_reply(OptionalScalars.encode(OptionalScalars.defaults, 0))
	}
	if context.request.path == "/optional-construct" {
		return scalar_reply(OptionalScalars.encode(OptionalScalars.{ unsigned32: Present(0.U32), signed32: Present(0.I32), signed64: Present(0.I64), zigzag32: Present(0.I32), zigzag64: Present(0.I64), signed_fixed32: Present(0.I32), signed_fixed64: Present(0.I64), enabled: Present(Bool.False), text: Present(""), float_value: Present(0.0.F32), double_value: Present(0.0.F64), unsigned64: Present(0.U64), fixed32_value: Present(0.U32), fixed64_value: Present(0.U64), payload: Present([]), implicit_value: 0 }, 4096))
	}
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 8, tags: 128, entries: 0, materialized_bytes: 512 }
	value = match OptionalScalars.decode(bytes, limits) {
		Ok(decoded) => decoded
		Err(error) => return Ok(Reply.text(Str.inspect(error)).with_status(400))
	}
	OptionalScalars.(record) = value
	if context.request.path == "/optional-view" {
		return Ok(
			Reply.text(
				Str.join_with(
					[
						presence_view(record.unsigned32, |item| item.to_str()),
						presence_view(record.signed32, |item| item.to_str()),
						presence_view(record.signed64, |item| item.to_str()),
						presence_view(record.zigzag32, |item| item.to_str()),
						presence_view(record.zigzag64, |item| item.to_str()),
						presence_view(record.signed_fixed32, |item| item.to_str()),
						presence_view(record.signed_fixed64, |item| item.to_str()),
						presence_view(
							record.enabled,
							|item| if item {
								"1"
							} else {
								"0"
							},
						),
						presence_view(record.text, |item| Str.count_utf8_bytes(item).to_str()),
						presence_view(record.float_value, |item| item.to_bits().to_str()),
						presence_view(record.double_value, |item| item.to_bits().to_str()),
						presence_view(record.unsigned64, |item| item.to_str()),
						presence_view(record.fixed32_value, |item| item.to_str()),
						presence_view(record.fixed64_value, |item| item.to_str()),
						presence_view(record.payload, |item| item.len().to_str()),
						record.implicit_value.to_str(),
					],
					",",
				),
			),
		)
	}
	if context.request.path == "/optional-text" {
		return Ok(
			Reply.bytes(
				match record.text {
					Absent => [0]
					Present(text) => [1].concat(text.to_utf8())
				},
				"application/octet-stream",
			),
		)
	}
	if context.request.path == "/optional-bytes" {
		return Ok(
			Reply.bytes(
				match record.payload {
					Absent => [0]
					Present(payload) => [1].concat(payload)
				},
				"application/octet-stream",
			),
		)
	}
	if context.request.path == "/optional-clear" {
		return scalar_reply(OptionalScalars.encode(OptionalScalars.({ ..record, unsigned32: Absent, text: Absent }), 4096))
	}
	scalar_reply(
		OptionalScalars.encode(
			value,
			if context.request.path == "/optional-limits" {
				16
			} else {
				4096
			},
		),
	)
}

presence_view = |value, render| match value {
	Absent => "-"
	Present(item) => render(item)
}

# Each discriminator selects a distinct generated nominal type and schema identity.
identity_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = ProtobufWire.default_limits
	if context.request.path == "/identity-empty" {
		Envelope.(_) = match Envelope.decode(bytes, limits) {
			Ok(value) => value
			Err(error) => return scalar_reply(Err(error))
		}
		EnvelopeEmpty.(_) = match EnvelopeEmpty.decode(bytes, limits) {
			Ok(value) => value
			Err(error) => return scalar_reply(Err(error))
		}
		return scalar_reply(EnvelopeEmpty.encode(EnvelopeEmpty.defaults, 0))
	}
	selector = match List.first(bytes) {
		Ok(value) => value
		Err(_) => return Ok(Reply.text("missing selector").with_status(400))
	}
	input = List.drop_first(bytes, 1)
	construct = context.request.path == "/identity-construct"
	view = context.request.path == "/identity-view"
	match selector {
		0 => {
			value = if construct {
				EnvelopePayload.{ text: Present("nested 🐦") }
			} else {
				match EnvelopePayload.decode(input, limits) {
					Ok(decoded) => decoded
					Err(error) => return scalar_reply(Err(error))
				}
			}
			EnvelopePayload.(record) = value
			if view {
				return Ok(
					Reply.text(
						match record.text {
							Absent => "absent"
							Present(text) => "present:${text}"
						},
					),
				)
			}
			scalar_reply(EnvelopePayload.encode(value, 4096))
		}
		1 => {
			value = if construct {
				Entry.{ count: 18446744073709551615 }
			} else {
				match Entry.decode(input, limits) {
					Ok(decoded) => decoded
					Err(error) => return scalar_reply(Err(error))
				}
			}
			Entry.(record) = value
			if view {
				return Ok(Reply.text(record.count.to_str()))
			}
			scalar_reply(Entry.encode(value, 4096))
		}
		2 => {
			value = if construct {
				EntryDetail.{ payload: [0, 128, 255] }
			} else {
				match EntryDetail.decode(input, limits) {
					Ok(decoded) => decoded
					Err(error) => return scalar_reply(Err(error))
				}
			}
			EntryDetail.(record) = value
			if view {
				return Ok(Reply.bytes(record.payload, "application/octet-stream"))
			}
			scalar_reply(EntryDetail.encode(value, 4096))
		}
		_ => Ok(Reply.text("unknown selector").with_status(400))
	}
}
