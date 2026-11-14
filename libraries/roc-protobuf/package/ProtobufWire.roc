## Schema-independent Protobuf wire operations. No gRPC envelopes or hosted effects.
ProtobufWire := [].{
	Limits : { input_bytes : U64, field_bytes : U64, depth : U64, tags : U64, entries : U64, materialized_bytes : U64 }

	default_limits : ProtobufWire.Limits
	default_limits = { input_bytes: 4194304, field_bytes: 4194304, depth: 64, tags: 65536, entries: 65536, materialized_bytes: 8388608 }

	Error : [Truncated, VarintOverflow, InvalidTag, InvalidWireType, UnexpectedEndGroup, MismatchedGroup, UnclosedGroup, InputLimit, FieldLimit, DepthLimit, TagLimit, EntryLimit, MaterializationLimit, UnfinishedMessage, NoParent, OutputLimit, InvalidUtf8]
	Kind : [Varint, Fixed64, Bytes, StartGroup, EndGroup, Fixed32]
	Tag : { number : U32, kind : ProtobufWire.Kind }

	Reader := { bytes : List(U8), position : U64, end : U64, parents : List(U64), limits : ProtobufWire.Limits, tags_left : U64, entries_left : U64, materialized_left : U64 }.{
		is_eq : _
	}

	new_reader : List(U8), ProtobufWire.Limits -> Try(ProtobufWire.Reader, ProtobufWire.Error)
	new_reader = |bytes, limits| {
		if bytes.len() > limits.input_bytes {
			return Err(InputLimit)
		}
		Ok(ProtobufWire.Reader.{ bytes, position: 0, end: bytes.len(), parents: [], limits, tags_left: limits.tags, entries_left: limits.entries, materialized_left: limits.materialized_bytes })
	}

	remaining : ProtobufWire.Reader -> U64
	remaining = |ProtobufWire.Reader.(state)| state.end - state.position

	## The returned reader must be threaded through subsequent operations.
	read_varint : ProtobufWire.Reader -> Try((U64, ProtobufWire.Reader), ProtobufWire.Error)
	read_varint = |ProtobufWire.Reader.(state)| {
		var $position = state.position
		var $value = 0.U64
		var $shift = 0.U8
		while $shift <= 63 {
			if $position == state.end {
				return Err(Truncated)
			}
			byte = state.bytes.get($position) ?? 0
			$position = $position + 1
			if $shift == 63 and byte > 1 {
				return Err(VarintOverflow)
			}
			$value = $value.bitwise_or(byte.bitwise_and(127).to_u64().shl_wrap($shift))
			if byte < 128 {
				return Ok(($value, ProtobufWire.Reader.({ ..state, position: $position })))
			}
			$shift = $shift + 7
		}
		Err(VarintOverflow)
	}

	## Every tag, including an end-group delimiter, consumes one tag budget unit.
	read_tag : ProtobufWire.Reader -> Try((ProtobufWire.Tag, ProtobufWire.Reader), ProtobufWire.Error)
	read_tag = |reader| {
		ProtobufWire.Reader.(state) = reader
		if state.tags_left == 0 {
			return Err(TagLimit)
		}
		(raw, ProtobufWire.Reader.(after)) = ProtobufWire.read_varint(reader)?
		number = raw.shr_zf_wrap(3)
		if number == 0 or number > 536870911 {
			return Err(InvalidTag)
		}
		kind = match raw.bitwise_and(7) {
			0 => Varint
			1 => Fixed64
			2 => Bytes
			3 => StartGroup
			4 => EndGroup
			5 => Fixed32
			_ => return Err(InvalidWireType)
		}
		Ok(({ number: number.to_u32_wrap(), kind }, ProtobufWire.Reader.({ ..after, tags_left: after.tags_left - 1 })))
	}

	read_fixed32 : ProtobufWire.Reader -> Try((U32, ProtobufWire.Reader), ProtobufWire.Error)
	read_fixed32 = |reader| {
		(value, after) = fixed(reader, 4)?
		Ok((value.to_u32_wrap(), after))
	}

	read_fixed64 : ProtobufWire.Reader -> Try((U64, ProtobufWire.Reader), ProtobufWire.Error)
	read_fixed64 = |reader| fixed(reader, 8)

	## Reads a length prefix and payload; charges materialization before slicing.
	read_bytes : ProtobufWire.Reader -> Try((List(U8), ProtobufWire.Reader), ProtobufWire.Error)
	read_bytes = |reader| {
		(length, ProtobufWire.Reader.(state)) = length_prefix(reader)?
		if length > state.materialized_left {
			return Err(MaterializationLimit)
		}
		value = state.bytes.sublist({ start: state.position, len: length })
		Ok((value, ProtobufWire.Reader.({ ..state, position: state.position + length, materialized_left: state.materialized_left - length })))
	}

	## Reads one length-delimited packed payload; the caller consumes its field tag.
	## Elements share the entry budget; a packed payload does not add message depth.
	read_packed_varints : ProtobufWire.Reader -> Try((List(U64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_varints = |reader| read_packed(reader, ProtobufWire.read_varint)

	read_packed_fixed32 : ProtobufWire.Reader -> Try((List(U32), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_fixed32 = |reader| read_packed(reader, ProtobufWire.read_fixed32)

	read_packed_fixed64 : ProtobufWire.Reader -> Try((List(U64), ProtobufWire.Reader), ProtobufWire.Error)
	read_packed_fixed64 = |reader| read_packed(reader, ProtobufWire.read_fixed64)

	## Enters a length-delimited message without copying. Root depth is zero.
	enter_message : ProtobufWire.Reader -> Try(ProtobufWire.Reader, ProtobufWire.Error)
	enter_message = |reader| {
		(length, ProtobufWire.Reader.(state)) = length_prefix(reader)?
		if state.parents.len() >= state.limits.depth {
			return Err(DepthLimit)
		}
		Ok(ProtobufWire.Reader.({ ..state, end: state.position + length, parents: state.parents.append(state.end) }))
	}

	## Leaving requires exact consumption; budgets are never restored.
	leave_message : ProtobufWire.Reader -> Try(ProtobufWire.Reader, ProtobufWire.Error)
	leave_message = |ProtobufWire.Reader.(state)| {
		if state.parents.is_empty() {
			return Err(NoParent)
		}
		if state.position != state.end {
			return Err(UnfinishedMessage)
		}
		parent = state.parents.last() ?? state.end
		Ok(ProtobufWire.Reader.({ ..state, end: parent, parents: state.parents.drop_last(1) }))
	}

	## Generated decoders charge entries before growing repeated/map collections,
	## including duplicates, and charge other copied storage before allocating it.
	reserve : ProtobufWire.Reader, U64, U64 -> Try(ProtobufWire.Reader, ProtobufWire.Error)
	reserve = |ProtobufWire.Reader.(state), entries, materialized_bytes| {
		if entries > state.entries_left {
			return Err(EntryLimit)
		}
		if materialized_bytes > state.materialized_left {
			return Err(MaterializationLimit)
		}
		Ok(ProtobufWire.Reader.({ ..state, entries_left: state.entries_left - entries, materialized_left: state.materialized_left - materialized_bytes }))
	}

	## Skip a tag's value. Unknown groups are matched iteratively, not recursively.
	## The caller has already read the tag and must pass its returned reader.
	skip : ProtobufWire.Reader, ProtobufWire.Tag -> Try(ProtobufWire.Reader, ProtobufWire.Error)
	skip = |reader, field| {
		if field.kind == EndGroup {
			return Err(UnexpectedEndGroup)
		}
		if field.kind != StartGroup {
			return skip_scalar(reader, field.kind)
		}
		ProtobufWire.Reader.(initial) = reader
		if initial.parents.len() >= initial.limits.depth {
			return Err(DepthLimit)
		}
		var $groups = [field.number]
		var $reader = reader
		while !$groups.is_empty() {
			if ProtobufWire.remaining($reader) == 0 {
				return Err(UnclosedGroup)
			}
			(next, after) = ProtobufWire.read_tag($reader)?
			$reader = after
			match next.kind {
				StartGroup => {
					if $groups.len() >= initial.limits.depth - initial.parents.len() {
						return Err(DepthLimit)
					}
					$groups = $groups.append(next.number)
				}
				EndGroup => {
					if ($groups.last() ?? 0) != next.number {
						return Err(MismatchedGroup)
					}
					$groups = $groups.drop_last(1)
				}
				_ => {
					$reader = skip_scalar($reader, next.kind)?
				}
			}
		}
		Ok($reader)
	}

	Writer := { bytes : List(U8), limit : U64 }.{
		is_eq : _
	}

	new_writer : U64 -> ProtobufWire.Writer
	new_writer = |limit| ProtobufWire.Writer.{ bytes: [], limit }

	output : ProtobufWire.Writer -> List(U8)
	output = |ProtobufWire.Writer.(state)| state.bytes

	## Remaining capacity lets schema codecs reject temporary conversions before copying.
	remaining_output : ProtobufWire.Writer -> U64
	remaining_output = |ProtobufWire.Writer.(state)| state.limit - state.bytes.len()

	write_varint : ProtobufWire.Writer, U64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_varint = |writer, value| append(writer, encoded_varint(value))

	write_tag : ProtobufWire.Writer, ProtobufWire.Tag -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_tag = |writer, field| {
		if field.number == 0 or field.number > 536870911 {
			return Err(InvalidTag)
		}
		kind : U64
		kind = match field.kind {
			Varint => 0
			Fixed64 => 1
			Bytes => 2
			StartGroup => 3
			EndGroup => 4
			Fixed32 => 5
		}
		ProtobufWire.write_varint(writer, field.number.to_u64() * 8 + kind)
	}

	write_fixed32 : ProtobufWire.Writer, U32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_fixed32 = |writer, value| append(writer, encoded_fixed(value.to_u64(), 4))

	write_fixed64 : ProtobufWire.Writer, U64 -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_fixed64 = |writer, value| append(writer, encoded_fixed(value, 8))

	## Encodes a length-delimited payload; the caller writes its field tag first.
	## The encoder must append to the supplied child writer and return it.
	write_message : ProtobufWire.Writer, value, (value, ProtobufWire.Writer -> Try(ProtobufWire.Writer, ProtobufWire.Error)) -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_message = |writer, value, encode_into| {
		available = ProtobufWire.remaining_output(writer)
		if available == 0 {
			return Err(OutputLimit)
		}
		# Reserve at least one prefix byte; write_bytes checks the actual prefix.
		child = encode_into(value, ProtobufWire.new_writer(available - 1))?
		ProtobufWire.write_bytes(writer, ProtobufWire.output(child))
	}

	write_bytes : ProtobufWire.Writer, List(U8) -> Try(ProtobufWire.Writer, ProtobufWire.Error)
	write_bytes = |ProtobufWire.Writer.(state), value| {
		prefix = encoded_varint(value.len())
		available = state.limit - state.bytes.len()
		if prefix.len() > available {
			return Err(OutputLimit)
		}
		if value.len() > available - prefix.len() {
			return Err(OutputLimit)
		}
		Ok(ProtobufWire.Writer.({ ..state, bytes: state.bytes.concat(prefix).concat(value) }))
	}
}

fixed : ProtobufWire.Reader, U64 -> Try((U64, ProtobufWire.Reader), ProtobufWire.Error)
fixed = |ProtobufWire.Reader.(state), width| {
	if width > state.end - state.position {
		return Err(Truncated)
	}
	var $value = 0.U64
	var $index = 0.U64
	while $index < width {
		byte = state.bytes.get(state.position + $index) ?? 0
		$value = $value.bitwise_or(byte.to_u64().shl_wrap(($index * 8).to_u8_wrap()))
		$index = $index + 1
	}
	Ok(($value, ProtobufWire.Reader.({ ..state, position: state.position + width })))
}

# Only internal scalar readers are passed here; each consumes at least one byte.
read_packed : ProtobufWire.Reader, (ProtobufWire.Reader -> Try((value, ProtobufWire.Reader), ProtobufWire.Error)) -> Try((List(value), ProtobufWire.Reader), ProtobufWire.Error)
read_packed = |reader, read_element| {
	(length, ProtobufWire.Reader.(initial)) = length_prefix(reader)?
	var $reader = ProtobufWire.Reader.({ ..initial, end: initial.position + length })
	var $values = []
	while ProtobufWire.remaining($reader) > 0 {
		reserved = ProtobufWire.reserve($reader, 1, 0)?
		(value, after) = read_element(reserved)?
		$values = $values.append(value)
		$reader = after
	}
	ProtobufWire.Reader.(final) = $reader
	Ok(($values, ProtobufWire.Reader.({ ..final, end: initial.end })))
}

length_prefix : ProtobufWire.Reader -> Try((U64, ProtobufWire.Reader), ProtobufWire.Error)
length_prefix = |reader| {
	(length, ProtobufWire.Reader.(state)) = ProtobufWire.read_varint(reader)?
	if length > state.limits.field_bytes {
		return Err(FieldLimit)
	}
	if length > state.end - state.position {
		return Err(Truncated)
	}
	Ok((length, ProtobufWire.Reader.(state)))
}

skip_scalar : ProtobufWire.Reader, ProtobufWire.Kind -> Try(ProtobufWire.Reader, ProtobufWire.Error)
skip_scalar = |reader, kind| {
	match kind {
		Varint => {
			(_, after) = ProtobufWire.read_varint(reader)?
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
			(length, ProtobufWire.Reader.(state)) = length_prefix(reader)?
			Ok(ProtobufWire.Reader.({ ..state, position: state.position + length }))
		}
		_ => Err(UnexpectedEndGroup)
	}
}

encoded_varint : U64 -> List(U8)
encoded_varint = |value| {
	var $value = value
	var $bytes = []
	while $value >= 128 {
		$bytes = $bytes.append($value.to_u8_wrap().bitwise_and(127).bitwise_or(128))
		$value = $value.shr_zf_wrap(7)
	}
	$bytes.append($value.to_u8_wrap())
}

encoded_fixed : U64, U64 -> List(U8)
encoded_fixed = |value, width| {
	var $bytes = []
	var $index = 0.U64
	while $index < width {
		$bytes = $bytes.append(value.shr_zf_wrap(($index * 8).to_u8_wrap()).to_u8_wrap())
		$index = $index + 1
	}
	$bytes
}

append : ProtobufWire.Writer, List(U8) -> Try(ProtobufWire.Writer, ProtobufWire.Error)
append = |ProtobufWire.Writer.(state), bytes| {
	if bytes.len() > state.limit - state.bytes.len() {
		return Err(OutputLimit)
	}
	Ok(ProtobufWire.Writer.({ ..state, bytes: state.bytes.concat(bytes) }))
}

expect {
	reader = ProtobufWire.new_reader([0x96, 0x01], ProtobufWire.default_limits)?
	(value, after) = ProtobufWire.read_varint(reader)?
	value == 150 and ProtobufWire.remaining(after) == 0
}

# Empty input is a valid empty message, but not a scalar value.
expect {
	r = ProtobufWire.new_reader([], ProtobufWire.default_limits)?
	ProtobufWire.remaining(r) == 0 and ProtobufWire.read_varint(r) == Err(Truncated)
}

# Every 7-bit width transition: nearest values below, at, and above.
expect {
	var $ok = Bool.True
	for shift in [7.U8, 14, 21, 28, 35, 42, 49, 56, 63] {
		boundary = (1.U64).shl_wrap(shift)
		for value in [boundary - 1, boundary, boundary + 1] {
			encoded = encoded_varint(value)
			r = ProtobufWire.new_reader(encoded, ProtobufWire.default_limits)?
			(decoded, after) = ProtobufWire.read_varint(r)?
			$ok = $ok and decoded == value and ProtobufWire.remaining(after) == 0
			$ok = $ok and encoded.len() == (shift / 7).to_u64() + (
				if value < boundary {
					0
				} else {
					1
				}
			)
		}
	}
	$ok
}

# Known wire vectors independently specify little endian and maximum varints.
expect {
	w = ProtobufWire.write_varint(ProtobufWire.new_writer(10), 18446744073709551615)?
	ProtobufWire.output(w) == [255, 255, 255, 255, 255, 255, 255, 255, 255, 1]
		and encoded_varint(0) == [0]
		and encoded_varint(150) == [150, 1]
}

expect {
	var $ok = Bool.True
	for last in [0.U8, 1, 2, 127, 128, 255] {
		bytes = List.repeat(255.U8, 9).append(last)
		r = ProtobufWire.new_reader(bytes, ProtobufWire.default_limits)?
		result = ProtobufWire.read_varint(r)
		$ok = $ok and if last <= 1 {
			(value, after) = result?
			value == (
				if last == 0 {
					9223372036854775807
				} else {
					18446744073709551615
				}
			) and ProtobufWire.remaining(after) == 0
		} else {
			result == Err(VarintOverflow)
		}
	}
	$ok
}

# Every incomplete prefix, plus legal non-minimal encodings through ten bytes.
expect {
	var $ok = Bool.True
	for count in [1.U64, 2, 3, 4, 5, 6, 7, 8, 9] {
		prefix = List.repeat(128.U8, count)
		r = ProtobufWire.new_reader(prefix, ProtobufWire.default_limits)?
		$ok = $ok and ProtobufWire.read_varint(r) == Err(Truncated)
		complete = ProtobufWire.new_reader(prefix.append(0), ProtobufWire.default_limits)?
		(value, after) = ProtobufWire.read_varint(complete)?
		$ok = $ok and value == 0 and ProtobufWire.remaining(after) == 0
	}
	$ok
}

# Tags use field numbers 1..2^29-1 and exactly six defined wire types.
expect {
	var $ok = Bool.True
	for number in [1.U32, 2, 18999, 19000, 19999, 20000, 536870910, 536870911] {
		for kind in [Varint, Fixed64, Bytes, StartGroup, EndGroup, Fixed32] {
			w = ProtobufWire.write_tag(ProtobufWire.new_writer(5), { number, kind })?
			r = ProtobufWire.new_reader(ProtobufWire.output(w), ProtobufWire.default_limits)?
			(field, after) = ProtobufWire.read_tag(r)?
			$ok = $ok and field == { number, kind } and ProtobufWire.remaining(after) == 0
		}
	}
	$ok
}

expect {
	var $ok = Bool.True
	for raw in [0.U64, 7, 4294967296, 18446744073709551615] {
		r = ProtobufWire.new_reader(encoded_varint(raw), ProtobufWire.default_limits)?
		$ok = $ok and ProtobufWire.read_tag(r) == Err(InvalidTag)
	}
	for raw in [14.U64, 15] {
		r = ProtobufWire.new_reader(encoded_varint(raw), ProtobufWire.default_limits)?
		$ok = $ok and ProtobufWire.read_tag(r) == Err(InvalidWireType)
	}
	for number in [0.U32, 536870912] {
		$ok = $ok and ProtobufWire.write_tag(ProtobufWire.new_writer(10), { number, kind: Varint }) == Err(InvalidTag)
	}
	$ok
}

expect {
	r = ProtobufWire.new_reader([0x78, 0x56, 0x34, 0x12, 9], ProtobufWire.default_limits)?
	(value, after) = ProtobufWire.read_fixed32(r)?
	w = ProtobufWire.write_fixed32(ProtobufWire.new_writer(4), value)?
	value == 0x12345678 and ProtobufWire.remaining(after) == 1 and ProtobufWire.output(w) == [0x78, 0x56, 0x34, 0x12]
}

expect {
	r = ProtobufWire.new_reader([8, 7, 6, 5, 4, 3, 2, 1, 9], ProtobufWire.default_limits)?
	(value, after) = ProtobufWire.read_fixed64(r)?
	w = ProtobufWire.write_fixed64(ProtobufWire.new_writer(8), value)?
	value == 0x0102030405060708 and ProtobufWire.remaining(after) == 1 and ProtobufWire.output(w) == [8, 7, 6, 5, 4, 3, 2, 1]
}

expect {
	var $ok = Bool.True
	for width in [4.U64, 8] {
		for count in [width - 1, width, width + 1] {
			r = ProtobufWire.new_reader(List.repeat(255.U8, count), ProtobufWire.default_limits)?
			result = fixed(r, width)
			$ok = $ok and if count < width {
				result == Err(Truncated)
			} else {
				(value, after) = result?
				value == (
					if width == 4 {
						4294967295
					} else {
						18446744073709551615
					}
				) and ProtobufWire.remaining(after) == count - width
			}
		}
	}
	$ok
}

# Input and field limits allow equality and zero; subtraction avoids overflow.
expect {
	limits = { ..ProtobufWire.default_limits, input_bytes: 4 }
	var $ok = Bool.True
	for size in [3.U64, 4, 5] {
		result = ProtobufWire.new_reader(List.repeat(0.U8, size), limits)
		$ok = $ok and if size > 4 {
			result == Err(InputLimit)
		} else {
			result.is_ok()
		}
	}
	empty = ProtobufWire.new_reader([], { ..limits, input_bytes: 0 })?
	$ok and ProtobufWire.remaining(empty) == 0
}

expect {
	limits = { ..ProtobufWire.default_limits, field_bytes: 4 }
	var $ok = Bool.True
	for size in [3.U64, 4, 5] {
		body = List.repeat(42.U8, size)
		r = ProtobufWire.new_reader(encoded_varint(size).concat(body).append(99), limits)?
		result = ProtobufWire.read_bytes(r)
		$ok = $ok and if size > 4 {
			result == Err(FieldLimit)
		} else {
			(value, after) = result?
			value == body and ProtobufWire.remaining(after) == 1
		}
	}
	r = ProtobufWire.new_reader([0], { ..limits, field_bytes: 0 })?
	(value, after) = ProtobufWire.read_bytes(r)?
	$ok and value.is_empty() and ProtobufWire.remaining(after) == 0
}

expect {
	limits = { ..ProtobufWire.default_limits, field_bytes: 18446744073709551615 }
	var $ok = Bool.True
	for bytes in [[2.U8, 42], encoded_varint(18446744073709551615)] {
		r = ProtobufWire.new_reader(bytes, limits)?
		$ok = $ok and ProtobufWire.read_bytes(r) == Err(Truncated)
	}
	$ok
}

# Copies and collection reservations consume a cumulative budget.
expect {
	var $ok = Bool.True
	for amount in [3.U64, 4, 5] {
		r = ProtobufWire.new_reader([], { ..ProtobufWire.default_limits, entries: 4, materialized_bytes: 4 })?
		$ok = $ok and if amount > 4 {
			ProtobufWire.reserve(r, amount, 0) == Err(EntryLimit) and ProtobufWire.reserve(r, 0, amount) == Err(MaterializationLimit)
		} else {
			after = ProtobufWire.reserve(r, amount, amount)?
			final = ProtobufWire.reserve(after, 4 - amount, 4 - amount)?
			ProtobufWire.reserve(final, 1, 0) == Err(EntryLimit) and ProtobufWire.reserve(final, 0, 1) == Err(MaterializationLimit)
		}
	}
	$ok
}

expect {
	r = ProtobufWire.new_reader([2, 1, 2, 2, 3, 4, 1, 5], { ..ProtobufWire.default_limits, materialized_bytes: 4 })?
	(_, first) = ProtobufWire.read_bytes(r)?
	(_, second) = ProtobufWire.read_bytes(first)?
	ProtobufWire.read_bytes(second) == Err(MaterializationLimit)
}

# Entering and leaving messages preserves all counters and exact input bounds.
expect {
	r = ProtobufWire.new_reader([2, 8, 0, 16, 0], { ..ProtobufWire.default_limits, depth: 1, tags: 1, entries: 1, materialized_bytes: 1 })?
	inside = ProtobufWire.enter_message(r)?
	(field, after_tag) = ProtobufWire.read_tag(inside)?
	after_reserve = ProtobufWire.reserve(after_tag, 1, 1)?
	(_, after_value) = ProtobufWire.read_varint(after_reserve)?
	outside = ProtobufWire.leave_message(after_value)?
	field == { number: 1, kind: Varint }
		and ProtobufWire.read_varint(after_value) == Err(Truncated)
		and ProtobufWire.remaining(outside) == 2
		and ProtobufWire.read_tag(outside) == Err(TagLimit)
		and ProtobufWire.reserve(outside, 1, 0) == Err(EntryLimit)
		and ProtobufWire.reserve(outside, 0, 1) == Err(MaterializationLimit)
}

expect {
	r = ProtobufWire.new_reader([1, 0], ProtobufWire.default_limits)?
	inside = ProtobufWire.enter_message(r)?
	ProtobufWire.leave_message(r) == Err(NoParent) and ProtobufWire.leave_message(inside) == Err(UnfinishedMessage)
}

# At depth two, zero-length children still consume a depth level.
expect {
	var $ok = Bool.True
	for depth in [1.U64, 2, 3] {
		r = ProtobufWire.new_reader([2, 1, 0], { ..ProtobufWire.default_limits, depth: 2 })?
		one = ProtobufWire.enter_message(r)?
		result = if depth == 1 {
			Ok(one)
		} else {
			two = ProtobufWire.enter_message(one)?
			if depth == 2 {
				Ok(two)
			} else {
				ProtobufWire.enter_message(two)
			}
		}
		$ok = $ok and if depth == 3 {
			result == Err(DepthLimit)
		} else {
			result.is_ok()
		}
	}
	zero = ProtobufWire.new_reader([0], { ..ProtobufWire.default_limits, depth: 0 })?
	$ok and ProtobufWire.enter_message(zero) == Err(DepthLimit)
}

# Unknown fields validate the wire but never materialize payload bytes.
expect {
	bytes = [8.U8, 150, 1, 17, 1, 2, 3, 4, 5, 6, 7, 8, 26, 3, 255, 0, 128, 37, 1, 2, 3, 4]
	r = ProtobufWire.new_reader(bytes, { ..ProtobufWire.default_limits, materialized_bytes: 0, entries: 0 })?
	ProtobufWire.remaining(skip_all(r)?) == 0
}

expect {
	var $ok = Bool.True
	for (bytes, error) in [([8.U8, 128], Truncated), ([17, 0], Truncated), ([26, 2, 0], Truncated), ([37, 0], Truncated), ([12], UnexpectedEndGroup), ([11], UnclosedGroup), ([11, 20], MismatchedGroup), ([11, 0], InvalidTag)] {
		r = ProtobufWire.new_reader(bytes, ProtobufWire.default_limits)?
		$ok = $ok and skip_all(r) == Err(error)
	}
	$ok
}

# Groups share depth with messages and consume tags including end delimiters.
expect {
	var $ok = Bool.True
	for limit in [3.U64, 4, 5] {
		r = ProtobufWire.new_reader([11, 19, 20, 12], { ..ProtobufWire.default_limits, tags: limit, depth: 2 })?
		result = skip_all(r)
		$ok = $ok and if limit < 4 {
			result == Err(TagLimit)
		} else {
			result.is_ok()
		}
	}
	for limit in [1.U64, 2, 3] {
		r = ProtobufWire.new_reader([11, 19, 20, 12], { ..ProtobufWire.default_limits, depth: limit })?
		result = skip_all(r)
		$ok = $ok and if limit < 2 {
			result == Err(DepthLimit)
		} else {
			result.is_ok()
		}
	}
	r = ProtobufWire.new_reader([2, 11, 12], { ..ProtobufWire.default_limits, depth: 1 })?
	inside = ProtobufWire.enter_message(r)?
	$ok and skip_all(inside) == Err(DepthLimit)
}

expect {
	r = ProtobufWire.new_reader([10, 2, 0, 0], { ..ProtobufWire.default_limits, field_bytes: 1 })?
	zero = ProtobufWire.new_reader([8, 0], { ..ProtobufWire.default_limits, tags: 0 })?
	skip_all(r) == Err(FieldLimit) and skip_all(zero) == Err(TagLimit)
}

# Every writer operation checks the complete output size before growth.
expect {
	var $ok = Bool.True
	for limit in [3.U64, 4, 5] {
		result = ProtobufWire.write_fixed32(ProtobufWire.new_writer(limit), 42)
		$ok = $ok and if limit < 4 {
			result == Err(OutputLimit)
		} else {
			result.is_ok()
		}
		data = ProtobufWire.write_bytes(ProtobufWire.new_writer(limit), [1, 2, 3])
		$ok = $ok and if limit < 4 {
			data == Err(OutputLimit)
		} else {
			ProtobufWire.output(data?) == [3, 1, 2, 3]
		}
	}
	for limit in [7.U64, 8, 9] {
		result = ProtobufWire.write_fixed64(ProtobufWire.new_writer(limit), 42)
		$ok = $ok and if limit < 8 {
			result == Err(OutputLimit)
		} else {
			result.is_ok()
		}
	}
	for limit in [9.U64, 10, 11] {
		result = ProtobufWire.write_varint(ProtobufWire.new_writer(limit), 18446744073709551615)
		$ok = $ok and if limit < 10 {
			result == Err(OutputLimit)
		} else {
			result.is_ok()
		}
	}
	full = ProtobufWire.write_varint(ProtobufWire.new_writer(1), 0)?
	$ok and ProtobufWire.write_bytes(full, []) == Err(OutputLimit)
		and ProtobufWire.write_varint(ProtobufWire.new_writer(0), 0) == Err(OutputLimit)
}

skip_all = |reader| {
	var $reader = reader
	while ProtobufWire.remaining($reader) > 0 {
		(field, after) = ProtobufWire.read_tag($reader)?
		$reader = ProtobufWire.skip(after, field)?
	}
	Ok($reader)
}

# Child output and its length prefix share the parent's remaining capacity.
expect {
	var $ok = Bool.True
	for size in [0.U64, 1, 126, 127, 128, 129] {
		payload = List.repeat(42.U8, size)
		needed = 1 + encoded_varint(size).len() + size
		for capacity in [needed - 1, needed, needed + 1] {
			parent = ProtobufWire.write_varint(ProtobufWire.new_writer(capacity), 7)?
			result = ProtobufWire.write_message(parent, payload, |bytes, child| append(child, bytes))
			$ok = $ok and if capacity < needed {
				result == Err(OutputLimit)
			} else {
				output = result?
				ProtobufWire.output(output) == [7].concat(encoded_varint(size)).concat(payload)
					and ProtobufWire.remaining_output(output) == capacity - needed
					and ProtobufWire.output(parent) == [7]
			}
		}
	}
	$ok
}

expect {
	parent = ProtobufWire.new_writer(0)
	# No capacity means the encoder is not called, even for an empty message.
	ProtobufWire.write_message(parent, {}, |_, _| Err(InvalidTag)) == Err(OutputLimit)
		and ProtobufWire.write_message(ProtobufWire.new_writer(1), {}, |_, _| Err(InvalidTag)) == Err(InvalidTag)
}

# Packed payloads preserve counters and parent bounds without adding depth.
expect {
	r = ProtobufWire.new_reader([2, 1, 2, 1, 3], { ..ProtobufWire.default_limits, depth: 0, entries: 2, materialized_bytes: 0, tags: 0 })?
	(values, after) = ProtobufWire.read_packed_varints(r)?
	values == [1, 2] and ProtobufWire.remaining(after) == 2
		and ProtobufWire.read_packed_varints(after) == Err(EntryLimit)
		and ProtobufWire.read_tag(after) == Err(TagLimit)
		and ProtobufWire.remaining(r) == 5
}

# A scalar ending outside the packed payload cannot borrow bytes from its parent.
expect {
	r = ProtobufWire.new_reader([1, 128, 1], ProtobufWire.default_limits)?
	ProtobufWire.read_packed_varints(r) == Err(Truncated)
}

expect {
	r = ProtobufWire.new_reader([0], { ..ProtobufWire.default_limits, depth: 0, entries: 0 })?
	(values, after) = ProtobufWire.read_packed_fixed64(r)?
	values.is_empty() and ProtobufWire.remaining(after) == 0
}

# Leaving a packed field restores the containing message, not the root scope.
expect {
	r = ProtobufWire.new_reader([3, 1, 7, 9, 42], { ..ProtobufWire.default_limits, depth: 1 })?
	inside = ProtobufWire.enter_message(r)?
	(values, after) = ProtobufWire.read_packed_varints(inside)?
	(tail, complete) = ProtobufWire.read_varint(after)?
	outside = ProtobufWire.leave_message(complete)?
	values == [7] and tail == 9 and ProtobufWire.remaining(outside) == 1
}
