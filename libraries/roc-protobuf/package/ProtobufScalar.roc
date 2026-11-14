## Typed scalar conversion over the bounded wire reader/writer.
import ProtobufWire

ProtobufScalar := [].{
	read_uint32 : ProtobufWire.Reader -> Try((U32, ProtobufWire.Reader), ProtobufWire.Error)
	read_uint32 = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((value.to_u32_wrap(), after))
	}

	write_uint32 : ProtobufWire.Writer, U32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_uint32 = |writer, value| ProtobufWire.write_varint(writer, value.to_u64())

	read_int32 : ProtobufWire.Reader -> Try((I32, ProtobufWire.Reader), ProtobufWire.Error)
	read_int32 = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((value.to_i32_wrap(), after))
	}

	write_int32 : ProtobufWire.Writer, I32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_int32 = |writer, value| ProtobufWire.write_varint(writer, value.to_i64().to_u64_wrap())

	read_int64 : ProtobufWire.Reader -> Try((I64, ProtobufWire.Reader), ProtobufWire.Error)
	read_int64 = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((value.to_i64_wrap(), after))
	}

	write_int64 : ProtobufWire.Writer, I64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_int64 = |writer, value| ProtobufWire.write_varint(writer, value.to_u64_wrap())

	read_sint32 : ProtobufWire.Reader -> Try((I32, ProtobufWire.Reader), ProtobufWire.Error)
	read_sint32 = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((decode_zigzag32(value.to_u32_wrap()), after))
	}

	write_sint32 : ProtobufWire.Writer, I32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_sint32 = |writer, value| ProtobufWire.write_varint(writer, value.shl_wrap(1).bitwise_xor(value.shr_wrap(31)).to_u32_wrap().to_u64())

	read_sint64 : ProtobufWire.Reader -> Try((I64, ProtobufWire.Reader), ProtobufWire.Error)
	read_sint64 = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((decode_zigzag64(value), after))
	}

	write_sint64 : ProtobufWire.Writer, I64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_sint64 = |writer, value| ProtobufWire.write_varint(writer, value.shl_wrap(1).bitwise_xor(value.shr_wrap(63)).to_u64_wrap())

	read_sfixed32 : ProtobufWire.Reader -> Try((I32, ProtobufWire.Reader), ProtobufWire.Error)
	read_sfixed32 = |reader| {
		(value, after) = ProtobufWire.read_fixed32(reader)?
		Ok((value.to_i32_wrap(), after))
	}

	write_sfixed32 : ProtobufWire.Writer, I32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_sfixed32 = |writer, value| ProtobufWire.write_fixed32(writer, value.to_u32_wrap())

	read_sfixed64 : ProtobufWire.Reader -> Try((I64, ProtobufWire.Reader), ProtobufWire.Error)
	read_sfixed64 = |reader| {
		(value, after) = ProtobufWire.read_fixed64(reader)?
		Ok((value.to_i64_wrap(), after))
	}

	write_sfixed64 : ProtobufWire.Writer, I64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_sfixed64 = |writer, value| ProtobufWire.write_fixed64(writer, value.to_u64_wrap())

	read_bool : ProtobufWire.Reader -> Try((Bool, ProtobufWire.Reader), ProtobufWire.Error)
	read_bool = |reader| {
		(value, after) = ProtobufWire.read_varint(reader)?
		Ok((value != 0, after))
	}

	write_bool : ProtobufWire.Writer, Bool -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_bool = |writer, value| ProtobufWire.write_varint(
		writer,
		if value {
			1
		} else {
			0
		},
	)

	read_float : ProtobufWire.Reader -> Try((F32, ProtobufWire.Reader), ProtobufWire.Error)
	read_float = |reader| {
		(value, after) = ProtobufWire.read_fixed32(reader)?
		Ok((F32.from_bits(value), after))
	}

	write_float : ProtobufWire.Writer, F32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_float = |writer, value| ProtobufWire.write_fixed32(writer, value.to_bits())

	read_double : ProtobufWire.Reader -> Try((F64, ProtobufWire.Reader), ProtobufWire.Error)
	read_double = |reader| {
		(value, after) = ProtobufWire.read_fixed64(reader)?
		Ok((F64.from_bits(value), after))
	}

	write_double : ProtobufWire.Writer, F64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_double = |writer, value| ProtobufWire.write_fixed64(writer, value.to_bits())

	## Packed scalar lists retain wire-reader budgets; elements are already reserved.
	read_packed_int32 : ProtobufWire.Reader -> Try((List(I32), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_int32 = |reader| {
		(values, after) = ProtobufWire.read_packed_varints(reader)?
		Ok((values.map(|value| value.to_i32_wrap()), after))
	}

	read_packed_int64 : ProtobufWire.Reader -> Try((List(I64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_int64 = |reader| {
		(values, after) = ProtobufWire.read_packed_varints(reader)?
		Ok((values.map(|value| value.to_i64_wrap()), after))
	}

	read_packed_sint32 : ProtobufWire.Reader -> Try((List(I32), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_sint32 = |reader| {
		(values, after) = ProtobufWire.read_packed_varints(reader)?
		Ok((values.map(|value| decode_zigzag32(value.to_u32_wrap())), after))
	}

	read_packed_sint64 : ProtobufWire.Reader -> Try((List(I64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_sint64 = |reader| {
		(values, after) = ProtobufWire.read_packed_varints(reader)?
		Ok((values.map(|value| decode_zigzag64(value)), after))
	}

	read_packed_sfixed32 : ProtobufWire.Reader -> Try((List(I32), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_sfixed32 = |reader| {
		(values, after) = ProtobufWire.read_packed_fixed32(reader)?
		Ok((values.map(|value| value.to_i32_wrap()), after))
	}

	read_packed_sfixed64 : ProtobufWire.Reader -> Try((List(I64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_sfixed64 = |reader| {
		(values, after) = ProtobufWire.read_packed_fixed64(reader)?
		Ok((values.map(|value| value.to_i64_wrap()), after))
	}

	read_packed_bool : ProtobufWire.Reader -> Try((List(Bool), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_bool = |reader| {
		(values, after) = ProtobufWire.read_packed_varints(reader)?
		Ok((values.map(|value| value != 0), after))
	}

	read_packed_float : ProtobufWire.Reader -> Try((List(F32), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_float = |reader| {
		(values, after) = ProtobufWire.read_packed_fixed32(reader)?
		Ok((values.map(|value| F32.from_bits(value)), after))
	}

	read_packed_double : ProtobufWire.Reader -> Try((List(F64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_double = |reader| {
		(values, after) = ProtobufWire.read_packed_fixed64(reader)?
		Ok((values.map(|value| F64.from_bits(value)), after))
	}

	## Charge both the byte slice and the UTF-8 conversion before materializing a string.
	read_string : ProtobufWire.Reader -> Try((Str, ProtobufWire.Reader), ProtobufWire.Error)
	read_string = |reader| {
		(bytes, after_bytes) = ProtobufWire.read_bytes(reader)?
		after_string = ProtobufWire.reserve(after_bytes, 0, bytes.len())?
		value = match Str.from_utf8(bytes) {
			Ok(text) => text
			Err(_) => return Err(InvalidUtf8)
		}
		Ok((value, after_string))
	}

	## Check the full length-prefixed output before allocating the UTF-8 byte list.
	write_string : ProtobufWire.Writer, Str -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_string = |writer, value| {
		length = Str.count_utf8_bytes(value)
		available = ProtobufWire.remaining_output(writer)
		if length > available {
			return Err(OutputLimit)
		}
		var $rest = length
		var $prefix = 1.U64
		while $rest >= 128 {
			$prefix = $prefix + 1
			$rest = $rest.shr_zf_wrap(7)
		}
		if $prefix > available - length {
			return Err(OutputLimit)
		}
		ProtobufWire.write_bytes(writer, value.to_utf8())
	}
}

# Unsigned arithmetic avoids negating the minimum signed value.
decode_zigzag32 : U32 -> I32
decode_zigzag32 = |value| value.shr_zf_wrap(1).bitwise_xor((0.U32).minus_wrap(value.bitwise_and(1))).to_i32_wrap()

decode_zigzag64 : U64 -> I64
decode_zigzag64 = |value| value.shr_zf_wrap(1).bitwise_xor((0.U64).minus_wrap(value.bitwise_and(1))).to_i64_wrap()

# ZigZag sign transitions and extreme values use wrapping shifts, never signed negation.
expect {
	decode_zigzag32(0) == 0 and decode_zigzag32(1) == -1 and decode_zigzag32(2) == 1
		and decode_zigzag32(4294967294) == 2147483647 and decode_zigzag32(4294967295) == -2147483648
		and decode_zigzag64(0) == 0 and decode_zigzag64(1) == -1 and decode_zigzag64(2) == 1
		and decode_zigzag64(18446744073709551614) == 9223372036854775807
		and decode_zigzag64(18446744073709551615) == -9223372036854775808
}

# Negative int32 is sign-extended to a ten-byte varint, unlike ZigZag.
expect {
	writer = ProtobufScalar.write_int32(ProtobufWire.new_writer(10), -1)?
	ProtobufWire.output(writer) == [255, 255, 255, 255, 255, 255, 255, 255, 255, 1]
		and ProtobufScalar.write_int32(ProtobufWire.new_writer(9), -1) == Err(OutputLimit)
}

# Native floats preserve every non-NaN bit pattern, including negative zero;
# Roc deliberately canonicalizes all NaN payloads when returning bits.
expect {
	var $ok = Bool.True
	for bits in [0.U32, 1, 0x007fffff, 0x00800000, 0x00800001, 0x7f7fffff, 0x7f800000, 0x80000000, 0xff800000] {
		$ok = $ok and F32.from_bits(bits).to_bits() == bits
	}
	for bits in [0.U64, 1, 0x000fffffffffffff, 0x0010000000000000, 0x0010000000000001, 0x7fefffffffffffff, 0x7ff0000000000000, 0x8000000000000000, 0xfff0000000000000] {
		$ok = $ok and F64.from_bits(bits).to_bits() == bits
	}
	$ok and F32.from_bits(0x7f800001).is_nan() and F32.from_bits(0xffffffff).to_bits() == 0x7fc00000
		and F64.from_bits(0x7ff0000000000001).is_nan() and F64.from_bits(0xffffffffffffffff).to_bits() == 0x7ff8000000000000
}

# The byte slice and string conversion each charge the UTF-8 byte length.
expect {
	var $ok = Bool.True
	for budget in [5.U64, 6, 7] {
		reader = ProtobufWire.new_reader([3, 0xe3, 0x81, 0x82], { ..ProtobufWire.default_limits, materialized_bytes: budget })?
		match ProtobufScalar.read_string(reader) {
			Ok((value, after)) => {
				$ok = $ok and budget >= 6 and value == "あ" and ProtobufWire.remaining(after) == 0
			}
			Err(error) => {
				$ok = $ok and budget < 6 and error == MaterializationLimit
			}
		}
	}
	$ok
}

# Invalid UTF-8 is rejected instead of substituting the replacement character.
expect {
	reader = ProtobufWire.new_reader([1, 255], ProtobufWire.default_limits)?
	ProtobufScalar.read_string(reader) == Err(InvalidUtf8)
}

# String output limits include the length prefix and count bytes, not code points.
expect {
	var $ok = Bool.True
	for limit in [3.U64, 4, 5] {
		result = ProtobufScalar.write_string(ProtobufWire.new_writer(limit), "あ")
		match result {
			Ok(writer) => {
				$ok = $ok and limit >= 4 and ProtobufWire.output(writer) == [3, 0xe3, 0x81, 0x82] and ProtobufWire.remaining_output(writer) == limit - 4
			}
			Err(error) => {
				$ok = $ok and limit < 4 and error == OutputLimit
			}
		}
	}
	$ok
}

# Crossing 128 UTF-8 bytes grows the varint prefix from one byte to two.
# Exercise remaining capacity after an existing byte as well as an empty writer.
expect {
	var $ok = Bool.True
	for (length, prefix) in [(127.U64, [127.U8]), (128, [128, 1]), (129, [129, 1])] {
		bytes = List.repeat(97.U8, length)
		text = Str.from_utf8(bytes)?
		expected = prefix.concat(bytes)
		for occupied in [0.U64, 1] {
			for capacity in [expected.len() - 1, expected.len(), expected.len() + 1] {
				initial = ProtobufWire.new_writer(occupied + capacity)
				writer = if occupied == 0 {
					initial
				} else {
					ProtobufWire.write_varint(initial, 42)?
				}
				match ProtobufScalar.write_string(writer, text) {
					Ok(after) => {
						output = if occupied == 0 {
							expected
						} else {
							[42.U8].concat(expected)
						}
						$ok = $ok and capacity >= expected.len() and ProtobufWire.output(after) == output
							and ProtobufWire.remaining_output(after) == capacity - expected.len()
					}
					Err(error) => {
						$ok = $ok and capacity < expected.len() and error == OutputLimit
					}
				}
			}
		}
	}
	$ok
}
