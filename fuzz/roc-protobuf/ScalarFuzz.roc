import ProtobufWire
import ProtobufScalar

ScalarFuzz := [].{
	check = |bytes| {
		_u32 = roundtrip(bytes, ProtobufScalar.read_uint32, ProtobufScalar.write_uint32)
		_i32 = roundtrip(bytes, ProtobufScalar.read_int32, ProtobufScalar.write_int32)
		_i64 = roundtrip(bytes, ProtobufScalar.read_int64, ProtobufScalar.write_int64)
		_s32 = roundtrip(bytes, ProtobufScalar.read_sint32, ProtobufScalar.write_sint32)
		_s64 = roundtrip(bytes, ProtobufScalar.read_sint64, ProtobufScalar.write_sint64)
		_sf32 = roundtrip(bytes, ProtobufScalar.read_sfixed32, ProtobufScalar.write_sfixed32)
		_sf64 = roundtrip(bytes, ProtobufScalar.read_sfixed64, ProtobufScalar.write_sfixed64)
		_bool = roundtrip(bytes, ProtobufScalar.read_bool, ProtobufScalar.write_bool)
		_float = roundtrip(bytes, ProtobufScalar.read_float, ProtobufScalar.write_float)
		_double = roundtrip(bytes, ProtobufScalar.read_double, ProtobufScalar.write_double)
		_string = roundtrip(bytes, ProtobufScalar.read_string, ProtobufScalar.write_string)
		{}
	}
}

# Compare canonical encodings rather than float equality (NaNs are supported).
roundtrip = |bytes, read, write| {
	limits = { ..ProtobufWire.default_limits, input_bytes: 4096, field_bytes: 4096, materialized_bytes: 8192 }
	reader = ProtobufWire.new_reader(bytes, limits)?
	(value, after) = read(reader)?
	if ProtobufWire.remaining(after) >= bytes.len() {
		crash "scalar reader did not advance"
	}
	# Once input has decoded, encoding and reading the canonical output must succeed.
	writer = match write(ProtobufWire.new_writer(4106), value) {
		Ok(encoded_writer) => encoded_writer
		Err(_) => crash "scalar encode unexpectedly failed"
	}
	encoded = ProtobufWire.output(writer)
	canonical_reader = match ProtobufWire.new_reader(encoded, limits) {
		Ok(ready_reader) => ready_reader
		Err(_) => crash "scalar encoding exceeded input bound"
	}
	(decoded, end) = match read(canonical_reader) {
		Ok(result) => result
		Err(_) => crash "scalar encoding could not be decoded"
	}
	second = match write(ProtobufWire.new_writer(4106), decoded) {
		Ok(encoded_writer) => encoded_writer
		Err(_) => crash "scalar re-encode unexpectedly failed"
	}
	if ProtobufWire.output(second) != encoded or ProtobufWire.remaining(end) != 0 {
		crash "scalar canonical roundtrip mismatch"
	}
	# Re-encoding the same value at exactly its length must fit; one byte less must fail.
	match write(ProtobufWire.new_writer(encoded.len()), value) {
		Ok(_) => {}
		Err(_) => crash "exact scalar output bound rejected"
	}
	if write(ProtobufWire.new_writer(encoded.len() - 1), value) != Err(OutputLimit) {
		crash "scalar output exceeded its limit"
	}
	Ok({})
}

expect ScalarFuzz.check([255, 255, 255, 255, 255, 255, 255, 255, 255, 1]) == {}
expect ScalarFuzz.check([3, 0xe3, 0x81, 0x82]) == {}
expect ScalarFuzz.check([1, 255]) == {}
