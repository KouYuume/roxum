app [program] { generated: "generated/main.roc", pf: platform "../../platform/main.roc", proto: "../../libraries/roc-protobuf/package/main.roc" }

import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Router
import pf.Server
import proto.ProtobufWire
import generated.ScalarLists
import generated.ScalarListEnvelope
import generated.UnsignedLists
import generated.UnsignedListEnvelope
import generated.RecursiveNodeRecursive
import generated.RecursiveEnvelope
import generated.ChoicePacket
import generated.ChoiceChild
import generated.ChoiceEnvelope
import generated.MapPacket
import generated.MapEnvelope
import generated.EnumPacket
import generated.EnumEnvelope
import generated.State
import generated.EnumPacketMode
import generated.Packet
import generated.Empty
import generated.Scalars
import generated.OptionalScalars
import generated.OptionalEnvelope
import generated.ScalarEnvelope
import generated.Top
import generated.MessageList
import generated.MessageListEnvelope
import generated.Collections
import generated.CollectionEnvelope
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
routes = Router.new.route("/recursive-defaults", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-chain", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-retained", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-construct", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-work", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-depth", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive-envelope", MethodRouter.post(Handler.stateful(recursive_answer))).route("/recursive", MethodRouter.post(Handler.stateful(recursive_answer))).route("/choice-depth", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-material", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-output", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-envelope", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-construct", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-retained", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice-view", MethodRouter.post(Handler.stateful(choice_answer))).route("/choice", MethodRouter.post(Handler.stateful(choice_answer))).route("/maps-material", MethodRouter.post(Handler.stateful(map_answer))).route("/maps-depth", MethodRouter.post(Handler.stateful(map_answer))).route("/maps-construct", MethodRouter.post(Handler.stateful(map_answer))).route("/maps-envelope", MethodRouter.post(Handler.stateful(map_answer))).route("/maps-output", MethodRouter.post(Handler.stateful(map_answer))).route("/maps", MethodRouter.post(Handler.stateful(map_answer))).route("/enum", MethodRouter.post(Handler.stateful(enum_answer))).route("/enum-view", MethodRouter.post(Handler.stateful(enum_answer))).route("/enum-construct", MethodRouter.post(Handler.stateful(enum_answer))).route("/enum-envelope", MethodRouter.post(Handler.stateful(enum_answer))).route("/enum-output", MethodRouter.post(Handler.stateful(enum_answer))).route("/scalar-lists", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/scalar-lists-view", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/scalar-lists-construct", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/scalar-lists-envelope", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/scalar-lists-output", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/scalar-lists-merge", MethodRouter.post(Handler.stateful(scalar_lists_answer))).route("/unsigned-lists", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-view", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-construct", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-envelope", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-output", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-zero-depth", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/unsigned-merge", MethodRouter.post(Handler.stateful(unsigned_answer))).route("/message-list", MethodRouter.post(Handler.stateful(message_list_answer))).route("/message-list-envelope", MethodRouter.post(Handler.stateful(message_list_answer))).route("/message-list-output", MethodRouter.post(Handler.stateful(message_list_answer))).route("/message-list-construct", MethodRouter.post(Handler.stateful(message_list_answer))).route("/collections", MethodRouter.post(Handler.stateful(collection_answer))).route("/collection-envelope", MethodRouter.post(Handler.stateful(collection_answer))).route("/collections-construct", MethodRouter.post(Handler.stateful(collection_answer))).route("/collections-output", MethodRouter.post(Handler.stateful(collection_answer))).route("/generated-construct", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/generated-message", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/generated-scalar-message", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/generated-top", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/generated-message-limit", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/generated-presence", MethodRouter.post(Handler.stateful(generated_message_answer))).route("/compose-message", MethodRouter.post(Handler.stateful(composition_answer))).route("/compose", MethodRouter.post(Handler.stateful(composition_answer))).route("/compose-scalars", MethodRouter.post(Handler.stateful(composition_answer))).route("/compose-retained", MethodRouter.post(Handler.stateful(composition_answer))).route("/compose-view", MethodRouter.post(Handler.stateful(composition_answer))).route("/compose-output", MethodRouter.post(Handler.stateful(composition_answer))).route("/identity-copy", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-view", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-construct", MethodRouter.post(Handler.stateful(identity_answer))).route("/identity-empty", MethodRouter.post(Handler.stateful(identity_answer))).route("/optional", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-view", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-text", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-bytes", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-construct", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-defaults", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-clear", MethodRouter.post(Handler.stateful(optional_answer))).route("/optional-limits", MethodRouter.post(Handler.stateful(optional_answer))).route("/scalars", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-view", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-text", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-construct", MethodRouter.post(Handler.stateful(scalar_answer))).route("/scalar-limits", MethodRouter.post(Handler.stateful(scalar_answer))).route("/copy", MethodRouter.post(Handler.stateful(answer))).route("/construct", MethodRouter.post(Handler.stateful(answer))).route("/defaults", MethodRouter.post(Handler.stateful(answer))).route("/view", MethodRouter.post(Handler.stateful(answer))).route("/empty", MethodRouter.post(Handler.stateful(answer))).route("/limits", MethodRouter.post(Handler.stateful(answer)))

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

composition_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 2, tags: 128, entries: 0, materialized_bytes: 512 }
	if context.request.path == "/compose-scalars" {
		(value, tail, _) = match read_envelope(bytes, limits, Scalars.defaults, Scalars.decode_into) {
			Ok(result) => result
			Err(error) => return scalar_reply(Err(error))
		}
		return scalar_reply(write_framed(value, tail, 4096, Scalars.encode_into))
	}
	(value, tail, first) = match read_envelope(bytes, limits, OptionalScalars.defaults, OptionalScalars.decode_into) {
		Ok(result) => result
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/compose-message" {
		return scalar_reply(write_envelope(value, tail))
	}
	OptionalScalars.(record) = value
	if context.request.path == "/compose-view" {
		unsigned = presence_view(record.unsigned32, |item| item.to_str())
		text = presence_view(record.text, |item| item)
		payload = presence_view(record.payload, |item| item.len().to_str())
		return Ok(Reply.text("${tail.to_str()},${unsigned},${text},${payload},${record.implicit_value.to_str()}"))
	}
	selected = if context.request.path == "/compose-retained" {
		first
	} else {
		value
	}
	capacity = if context.request.path == "/compose-output" {
		16
	} else {
		4096
	}
	scalar_reply(write_framed(selected, tail, capacity, OptionalScalars.encode_into))
}

# Handwritten outer driver: generated scalar codecs own only the entered scope.
read_envelope = |bytes, limits, initial, decode_into| {
	var $reader = ProtobufWire.new_reader(bytes, limits)?
	var $value = initial
	var $first = initial
	var $seen = Bool.False
	var $tail = 0.U32
	while ProtobufWire.remaining($reader) > 0 {
		(field, after_tag) = ProtobufWire.read_tag($reader)?
		$reader = after_tag
		match (field.number, field.kind) {
			(1, Bytes) => {
				inside = ProtobufWire.enter_message($reader)?
				(merged, after_child) = decode_into(inside, $value)?
				$value = merged
				if !$seen {
					$first = merged
					$seen = Bool.True
				}
				$reader = ProtobufWire.leave_message(after_child)?
			}
			(2, Varint) => {
				(tail, after) = ProtobufWire.read_varint($reader)?
				$tail = tail.to_u32_wrap()
				$reader = after
			}
			_ => {
				$reader = ProtobufWire.skip($reader, field)?
			}
		}
	}
	Ok(($value, $tail, $first))
}

# Test transport framing proves that codec output preserves a prefix and leaves
# the shared capacity for a suffix. It is not a Protobuf nested-message encoder.
write_framed = |value, tail, capacity, encode_into| {
	prefix = ProtobufWire.write_fixed32(ProtobufWire.new_writer(capacity), 0x44332211)?
	fields = encode_into(value, prefix)?
	# Empty codecs must preserve both the accumulated bytes and the limit.
	unchanged = Empty.encode_into(Empty.defaults, fields)?
	complete = ProtobufWire.write_fixed32(unchanged, tail)?
	Ok(ProtobufWire.output(complete))
}

write_envelope = |value, tail| {
	tagged = ProtobufWire.write_tag(ProtobufWire.new_writer(256), { number: 1, kind: Bytes })?
	child = ProtobufWire.write_message(tagged, value, OptionalScalars.encode_into)?
	tail_tag = ProtobufWire.write_tag(child, { number: 2, kind: Varint })?
	complete = ProtobufWire.write_varint(tail_tag, tail.to_u64())?
	Ok(ProtobufWire.output(complete))
}

generated_message_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 2, tags: 128, entries: 0, materialized_bytes: 512 }
	if context.request.path == "/generated-construct" {
		OptionalScalars.(defaults) = OptionalScalars.defaults
		child = OptionalScalars.{ ..defaults, text: Present(""), unsigned32: Present(0) }
		return scalar_reply(OptionalEnvelope.encode(OptionalEnvelope.{ child: Present(child), tail: 42 }, 4096))
	}
	if context.request.path == "/generated-top" {
		return scalar_reply(copy_generated(bytes, limits, Top.decode, Top.encode))
	}
	if context.request.path == "/generated-scalar-message" {
		return scalar_reply(copy_generated(bytes, limits, ScalarEnvelope.decode, ScalarEnvelope.encode))
	}
	value = match OptionalEnvelope.decode(bytes, limits) {
		Ok(decoded) => decoded
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/generated-presence" {
		OptionalEnvelope.(record) = value
		return Ok(
			Reply.text(
				match record.child {
					Absent => "absent"
					Present(_) => "present"
				},
			),
		)
	}
	capacity = if context.request.path == "/generated-message-limit" {
		256
	} else {
		4096
	}
	scalar_reply(OptionalEnvelope.encode(value, capacity))
}

copy_generated = |bytes, limits, decode, encode| {
	value = decode(bytes, limits)?
	encode(value, 4096)
}

collection_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 2, tags: 128, entries: 4, materialized_bytes: 512 }
	if context.request.path == "/collections-construct" {
		return scalar_reply(Collections.encode(Collections.{ texts: ["", "hello", ""], chunks: [[], [0, 255]] }, 4096))
	}
	if context.request.path == "/collection-envelope" {
		return scalar_reply(copy_generated(bytes, limits, CollectionEnvelope.decode, CollectionEnvelope.encode))
	}
	decoded = match Collections.decode(bytes, limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	capacity = if context.request.path == "/collections-output" {
		16
	} else {
		4096
	}
	scalar_reply(Collections.encode(decoded, capacity))
}

message_list_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 2, tags: 128, entries: 4, materialized_bytes: 512 }
	if context.request.path == "/message-list-construct" {
		return scalar_reply(MessageList.encode(MessageList.{ children: [Collections.defaults, Collections.{ texts: ["a"], chunks: [] }, Collections.defaults] }, 4096))
	}
	if context.request.path == "/message-list-envelope" {
		return scalar_reply(copy_generated(bytes, limits, MessageListEnvelope.decode, MessageListEnvelope.encode))
	}
	decoded = match MessageList.decode(bytes, limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	capacity = if context.request.path == "/message-list-output" {
		16
	} else {
		4096
	}
	scalar_reply(MessageList.encode(decoded, capacity))
}

unsigned_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 1, tags: 128, entries: 64, materialized_bytes: 0 }
	if context.request.path == "/unsigned-envelope" {
		return scalar_reply(copy_generated(bytes, limits, UnsignedListEnvelope.decode, UnsignedListEnvelope.encode))
	}
	if context.request.path == "/unsigned-construct" {
		value = UnsignedLists.{ unsigned32: [0, 4294967295], unsigned64: [0, 18446744073709551615], fixed32_value: [0, 4294967295], fixed64_value: [0, 18446744073709551615], expanded32: [0, 4294967295], expanded64: [0, 18446744073709551615], expanded_fixed32: [0, 4294967295], expanded_fixed64: [0, 18446744073709551615] }
		return scalar_reply(UnsignedLists.encode(value, 4096))
	}
	if context.request.path == "/unsigned-merge" {
		return scalar_reply(unsigned_merge(bytes, limits))
	}
	selected_limits = if context.request.path == "/unsigned-zero-depth" {
		{ ..limits, depth: 0 }
	} else {
		limits
	}
	decoded = match UnsignedLists.decode(bytes, selected_limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/unsigned-view" {
		UnsignedLists.(value) = decoded
		return Ok(
			Reply.text(
				Str.join_with(
					[
						Str.join_with(value.unsigned32.map(|n| n.to_str()), ","),
						Str.join_with(value.unsigned64.map(|n| n.to_str()), ","),
						Str.join_with(value.fixed32_value.map(|n| n.to_str()), ","),
						Str.join_with(value.fixed64_value.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded32.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded64.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_fixed32.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_fixed64.map(|n| n.to_str()), ","),
					],
					";",
				),
			),
		)
	}
	capacity = if context.request.path == "/unsigned-output" {
		16
	} else {
		4096
	}
	scalar_reply(UnsignedLists.encode(decoded, capacity))
}

unsigned_merge = |bytes, limits| {
	UnsignedLists.(defaults) = UnsignedLists.defaults
	initial = UnsignedLists.{ ..defaults, unsigned32: [42] }
	reader = ProtobufWire.new_reader(bytes, limits)?
	(merged, _) = UnsignedLists.decode_into(reader, initial)?
	original = UnsignedLists.encode(initial, 4096)?
	writer = ProtobufWire.write_bytes(ProtobufWire.new_writer(4096), original)?
	result = UnsignedLists.encode_into(merged, writer)?
	Ok(ProtobufWire.output(result))
}

scalar_lists_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 0, tags: 128, entries: 64, materialized_bytes: 0 }
	if context.request.path == "/scalar-lists-envelope" {
		return scalar_reply(copy_generated(bytes, { ..limits, depth: 1 }, ScalarListEnvelope.decode, ScalarListEnvelope.encode))
	}
	if context.request.path == "/scalar-lists-construct" {
		value = ScalarLists.{ signed32: [-2147483648, 0, 2147483647], signed64: [-9223372036854775808, 0, 9223372036854775807], zigzag32: [-2147483648, 0, 2147483647], zigzag64: [-9223372036854775808, 0, 9223372036854775807], signed_fixed32: [-2147483648, 0, 2147483647], signed_fixed64: [-9223372036854775808, 0, 9223372036854775807], enabled: [Bool.False, Bool.True], float_value: [0.0.F32, F32.from_bits(0x80000000), F32.infinity, F32.from_bits(0x7fc00001)], double_value: [0.0.F64, F64.from_bits(0x8000000000000000), F64.infinity, F64.from_bits(0x7ff8000000000001)], expanded_signed32: [-2147483648, 0, 2147483647], expanded_signed64: [-9223372036854775808, 0, 9223372036854775807], expanded_zigzag32: [-2147483648, 0, 2147483647], expanded_zigzag64: [-9223372036854775808, 0, 9223372036854775807], expanded_signed_fixed32: [-2147483648, 0, 2147483647], expanded_signed_fixed64: [-9223372036854775808, 0, 9223372036854775807], expanded_enabled: [Bool.False, Bool.True], expanded_float_value: [0.0.F32, F32.from_bits(0x80000000), F32.infinity, F32.from_bits(0x7fc00001)], expanded_double_value: [0.0.F64, F64.from_bits(0x8000000000000000), F64.infinity, F64.from_bits(0x7ff8000000000001)] }
		return scalar_reply(ScalarLists.encode(value, 4096))
	}
	if context.request.path == "/scalar-lists-merge" {
		return scalar_reply(scalar_lists_merge(bytes, limits))
	}
	decoded = match ScalarLists.decode(bytes, limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/scalar-lists-view" {
		ScalarLists.(value) = decoded
		return Ok(
			Reply.text(
				Str.join_with(
					[
						Str.join_with(value.signed32.map(|n| n.to_str()), ","),
						Str.join_with(value.signed64.map(|n| n.to_str()), ","),
						Str.join_with(value.zigzag32.map(|n| n.to_str()), ","),
						Str.join_with(value.zigzag64.map(|n| n.to_str()), ","),
						Str.join_with(value.signed_fixed32.map(|n| n.to_str()), ","),
						Str.join_with(value.signed_fixed64.map(|n| n.to_str()), ","),
						Str.join_with(
							value.enabled.map(
								|n| if n {
									"1"
								} else {
									"0"
								},
							),
							",",
						),
						Str.join_with(value.float_value.map(|n| n.to_bits().to_str()), ","),
						Str.join_with(value.double_value.map(|n| n.to_bits().to_str()), ","),
						Str.join_with(value.expanded_signed32.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_signed64.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_zigzag32.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_zigzag64.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_signed_fixed32.map(|n| n.to_str()), ","),
						Str.join_with(value.expanded_signed_fixed64.map(|n| n.to_str()), ","),
						Str.join_with(
							value.expanded_enabled.map(
								|n| if n {
									"1"
								} else {
									"0"
								},
							),
							",",
						),
						Str.join_with(value.expanded_float_value.map(|n| n.to_bits().to_str()), ","),
						Str.join_with(value.expanded_double_value.map(|n| n.to_bits().to_str()), ","),
					],
					";",
				),
			),
		)
	}
	capacity = if context.request.path == "/scalar-lists-output" {
		16
	} else {
		4096
	}
	scalar_reply(ScalarLists.encode(decoded, capacity))
}

scalar_lists_merge = |bytes, limits| {
	ScalarLists.(defaults) = ScalarLists.defaults
	initial = ScalarLists.{ ..defaults, signed32: [-42], float_value: [F32.from_bits(0x80000000)] }
	reader = ProtobufWire.new_reader(bytes, limits)?
	(merged, _) = ScalarLists.decode_into(reader, initial)?
	original = ScalarLists.encode(initial, 4096)?
	writer = ProtobufWire.write_bytes(ProtobufWire.new_writer(4096), original)?
	result = ScalarLists.encode_into(merged, writer)?
	Ok(ProtobufWire.output(result))
}

enum_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 1, tags: 128, entries: 64, materialized_bytes: 0 }
	if context.request.path == "/enum-envelope" {
		return scalar_reply(copy_generated(bytes, limits, EnumEnvelope.decode, EnumEnvelope.encode))
	}
	if context.request.path == "/enum-construct" {
		value = EnumPacket.{ state: State.state_negative, selected: Present(State.state_zero), states: [State.state_ready, State.state_available, State.from_number(-2147483648)], expanded: [State.from_number(2147483647)], mode: EnumPacketMode.mode_on }
		return scalar_reply(EnumPacket.encode(value, 4096))
	}
	decoded = match EnumPacket.decode(bytes, limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/enum-view" {
		EnumPacket.(value) = decoded
		presence = match value.selected {
			Absent => "absent"
			Present(item) => State.to_number(item).to_str()
		}
		states = Str.join_with(value.states.map(|item| State.to_number(item).to_str()), ",")
		expanded = Str.join_with(value.expanded.map(|item| State.to_number(item).to_str()), ",")
		return Ok(Reply.text("${State.to_number(value.state).to_str()};${presence};${states};${expanded};${EnumPacketMode.to_number(value.mode).to_str()}"))
	}
	capacity = if context.request.path == "/enum-output" {
		16
	} else {
		4096
	}
	scalar_reply(EnumPacket.encode(decoded, capacity))
}

map_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 3, tags: 256, entries: 64, materialized_bytes: 512 }
	if context.request.path == "/maps-envelope" {
		return scalar_reply(copy_generated(bytes, limits, MapEnvelope.decode, MapEnvelope.encode))
	}
	if context.request.path == "/maps-construct" {
		MapPacket.(defaults) = MapPacket.defaults
		Packet.(empty) = Packet.defaults
		value = MapPacket.{
			..defaults,
			signed32: Dict.from_list([(-1, "old"), (-1, "new"), (0, "")]),
			signed64: Dict.from_list([(-9223372036854775808, State.from_number(-7))]),
			unsigned32: Dict.from_list([(4294967295, [0, 255])]),
			unsigned64: Dict.from_list([(18446744073709551615, "heap-backed map value 🐦")]),
			flags: Dict.from_list([(Bool.False, Packet.defaults), (Bool.True, Packet.{ ..empty, count: 7 })]),
			strings: Dict.from_list([("", Packet.defaults), ("heap-backed map key 🐦", Packet.{ ..empty, code: 9 })]),
			zigzag32: Dict.from_list([(-2147483648, -2)]),
			zigzag64: Dict.from_list([(-9223372036854775808, -3)]),
			fixed32: Dict.from_list([(4294967295, -1.5)]),
			fixed64: Dict.from_list([(18446744073709551615, 2.5)]),
			sfixed32: Dict.from_list([(-2147483648, Bool.True)]),
			sfixed64: Dict.from_list([(-9223372036854775808, 18446744073709551615)]),
		}
		return scalar_reply(MapPacket.encode(value, 4096))
	}
	selected = if context.request.path == "/maps-depth" {
		{ ..limits, depth: 1 }
	} else if context.request.path == "/maps-material" {
		{ ..limits, materialized_bytes: 16 }
	} else {
		limits
	}
	decoded = match MapPacket.decode(bytes, selected) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	capacity = if context.request.path == "/maps-output" {
		16
	} else {
		4096
	}
	scalar_reply(MapPacket.encode(decoded, capacity))
}

choice_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 256, depth: 3, tags: 128, entries: 64, materialized_bytes: 512 }
	if context.request.path == "/choice-envelope" {
		return scalar_reply(copy_generated(bytes, limits, ChoiceEnvelope.decode, ChoiceEnvelope.encode))
	}
	if context.request.path == "/choice-construct" {
		ChoicePacket.(defaults) = ChoicePacket.defaults
		value = ChoicePacket.{ ..defaults, choice: State(State.from_number(-7)), secondary: Extra([]), marker: Present(0), outside: 9 }
		return scalar_reply(ChoicePacket.encode(value, 4096))
	}
	selected = if context.request.path == "/choice-material" {
		{ ..limits, materialized_bytes: 16 }
	} else if context.request.path == "/choice-depth" {
		{ ..limits, depth: 0 }
	} else {
		limits
	}
	decoded = match ChoicePacket.decode(bytes, selected) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/choice-view" {
		return Ok(Reply.text(choice_view(decoded)))
	}
	if context.request.path == "/choice-retained" {
		before = choice_view(decoded)
		ChoicePacket.(record) = decoded
		cleared = ChoicePacket.{ ..record, choice: Unset, secondary: Unset }
		return Ok(Reply.text("${before};${choice_view(cleared)};${choice_view(decoded)}"))
	}
	capacity = if context.request.path == "/choice-output" {
		16
	} else {
		4096
	}
	scalar_reply(ChoicePacket.encode(decoded, capacity))
}

choice_view = |ChoicePacket.(value)| {
	selection = match value.choice {
		Unset => "unset"
		Unsigned64(item) => "unsigned64:${item.to_str()}"
		Unsigned32(item) => "unsigned32:${item.to_str()}"
		Signed32(item) => "signed32:${item.to_str()}"
		Signed64(item) => "signed64:${item.to_str()}"
		Zigzag32(item) => "zigzag32:${item.to_str()}"
		Zigzag64(item) => "zigzag64:${item.to_str()}"
		Fixed32Value(item) => "fixed32_value:${item.to_str()}"
		Fixed64Value(item) => "fixed64_value:${item.to_str()}"
		SignedFixed32(item) => "signed_fixed32:${item.to_str()}"
		SignedFixed64(item) => "signed_fixed64:${item.to_str()}"

		Enabled(item) => if item {
			"enabled:true"
		} else {
			"enabled:false"
		}
		Text(item) => "text:${item}"
		Payload(item) => "payload:${choice_bytes(item)}"
		FloatValue(_) => "float_value"
		DoubleValue(_) => "double_value"
		State(item) => "state:${State.to_number(item).to_str()}"
		ChildValue(item) => "child_value:${choice_child(item)}"
		OtherChild(item) => "other_child:${choice_child(item)}"
	}
	secondary = match value.secondary {
		Unset => "unset"
		Extra(item) => "extra:${choice_bytes(item)}"
	}
	marker = match value.marker {
		Absent => "absent"
		Present(item) => item.to_str()
	}
	"${selection}/${secondary}/${marker}/${value.outside.to_str()}"
}

choice_bytes = |bytes| Str.join_with(bytes.map(|byte| byte.to_str()), ",")

choice_child = |ChoiceChild.(value)| "${value.text}|${Str.join_with(value.numbers.map(|number| number.to_str()), ",")}|${Dict.len(value.labels).to_str()}"

recursive_answer = |_model, context| {
	bytes = match context.request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	limits = { input_bytes: 4096, field_bytes: 4096, depth: 8, tags: 256, entries: 128, materialized_bytes: 1024 }
	if context.request.path == "/recursive-envelope" {
		return scalar_reply(copy_generated(bytes, limits, RecursiveEnvelope.decode, RecursiveEnvelope.encode))
	}
	if context.request.path == "/recursive-construct" or context.request.path == "/recursive-chain" {
		chain = context.request.path == "/recursive-chain"
		if bytes.len() != 1 {
			return Ok(Reply.text("InputLength").with_status(400))
		}
		depth = (bytes.get(0) ?? 0).to_u64()
		if depth > (
			if chain {
				65
			} else {
				64
			}
		) {
			return Ok(Reply.text("DepthLimit").with_status(400))
		}
		var $node = RecursiveNodeRecursive.RecursiveNode.defaults
		var $index = 0.U64
		while $index < depth {
			RecursiveNodeRecursive.RecursiveNode.(record) = $node
			$node = if chain {
				RecursiveNodeRecursive.RecursiveNode.{ ..record, next: Present(Box.box($node)) }
			} else {
				RecursiveNodeRecursive.RecursiveNode.{ ..record, children: [$node, $node] }
			}
			$index = $index + 1
		}
		writer = ProtobufWire.new_writer_with_limits({
			output_bytes: 4096,
			depth: 64,
			messages: if chain {
				65536
			} else {
				16
			},
		})
		return scalar_reply(recursive_output(RecursiveNodeRecursive.RecursiveNode.encode_into($node, writer)))
	}
	decode_limits = if context.request.path == "/recursive-defaults" {
		ProtobufWire.default_limits
	} else {
		limits
	}
	decoded = match RecursiveNodeRecursive.RecursiveNode.decode(bytes, decode_limits) {
		Ok(value) => value
		Err(error) => return scalar_reply(Err(error))
	}
	if context.request.path == "/recursive-retained" {
		before = recursive_stats(decoded)
		RecursiveNodeRecursive.RecursiveNode.(record) = decoded
		cleared = RecursiveNodeRecursive.RecursiveNode.{ ..record, next: Absent, children: [], lookup: Dict.empty(), choice: Unset }
		return Ok(Reply.text("${before};${recursive_stats(cleared)};${recursive_stats(decoded)}"))
	}
	depth = if context.request.path == "/recursive-depth" {
		3
	} else {
		64
	}
	messages = if context.request.path == "/recursive-work" {
		4
	} else {
		65536
	}
	writer = ProtobufWire.new_writer_with_limits({ output_bytes: 4096, depth, messages })
	scalar_reply(recursive_output(RecursiveNodeRecursive.RecursiveNode.encode_into(decoded, writer)))
}

recursive_stats = |node| {
	(nodes, sum) = recursive_count(node)
	"${nodes.to_str()},${sum.to_str()}"
}

recursive_count : RecursiveNodeRecursive.RecursiveNode -> (U64, U64)
recursive_count = |RecursiveNodeRecursive.RecursiveNode.(record)| {
	var $nodes = 1.U64
	var $sum = record.value.to_u64()
	var $children = record.children
	match record.next {
		Absent => {}
		Present(value) => {
			$children = $children.append(Box.unbox(value))
		}
	}
	match record.choice {
		Selected(value) => {
			$children = $children.append(Box.unbox(value))
		}
		_ => {}
	}
	for (_, child) in record.lookup {
		$children = $children.append(child)
	}
	for child in $children {
		(nodes, sum) = recursive_count(child)
		$nodes = $nodes + nodes
		$sum = $sum + sum
	}
	($nodes, $sum)
}

recursive_output = |result| match result {
	Ok(writer) => Ok(ProtobufWire.output(writer))
	Err(error) => Err(error)
}
