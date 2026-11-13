app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import ProtobufWire
import ScopeFuzz

target = Fuzz.target_with({
	name: "protobuf-wire",
	generator: Fuzz.raw_bytes,
	show: |bytes| Str.inspect(bytes),
	test: |bytes| {
		ScopeFuzz.check(bytes)
		match check(bytes) {
			Ok({}) => Fuzz.keep
			Err(_) => Fuzz.keep
		}
	},
})

check : List(U8) -> Try({}, ProtobufWire.Error)
check = |bytes| {
	limits = { ..ProtobufWire.default_limits, input_bytes: 4096, field_bytes: 4096, materialized_bytes: 4096, tags: 256, depth: 16 }
	var $reader = ProtobufWire.new_reader(bytes, limits)?
	while ProtobufWire.remaining($reader) > 0 {
		before = ProtobufWire.remaining($reader)
		(field, after_tag) = ProtobufWire.read_tag($reader)?
		discarded = ProtobufWire.skip(after_tag, field)
		if field.kind != StartGroup and field.kind != EndGroup {
			read = consume(after_tag, field.kind)
			match (discarded, read) {
				(Ok(a), Ok(b)) => {
					if ProtobufWire.remaining(a) != ProtobufWire.remaining(b) {
						crash "read/skip cursor mismatch"
					}
				}
				(Err(a), Err(b)) => {
					if a != b {
						crash "read/skip error mismatch"
					}
				}
				_ => crash "read/skip acceptance mismatch"
			}
		}
		$reader = discarded?
		if ProtobufWire.remaining($reader) >= before {
			crash "wire parser did not advance"
		}
	}
	Ok({})
}

consume = |reader, kind| {
	match kind {
		Varint => {
			(value, after) = ProtobufWire.read_varint(reader)?
			writer = ProtobufWire.write_varint(ProtobufWire.new_writer(10), value)?
			roundtrip = ProtobufWire.new_reader(ProtobufWire.output(writer), ProtobufWire.default_limits)?
			(decoded, end) = ProtobufWire.read_varint(roundtrip)?
			if value != decoded or ProtobufWire.remaining(end) != 0 {
				crash "varint roundtrip mismatch"
			}
			Ok(after)
		}
		Fixed64 => {
			(_, after) = ProtobufWire.read_fixed64(reader)?
			Ok(after)
		}
		Fixed32 => {
			(_, after) = ProtobufWire.read_fixed32(reader)?
			Ok(after)
		}
		Bytes => {
			(_, after) = ProtobufWire.read_bytes(reader)?
			Ok(after)
		}
		_ => Err(UnexpectedEndGroup)
	}
}
