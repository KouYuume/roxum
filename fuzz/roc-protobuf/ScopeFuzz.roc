import ProtobufWire

## Generate valid nested wire messages so fuzzing reaches scope exits and
## cumulative limits even when arbitrary input is usually rejected at its tag.
ScopeFuzz := [].{
	check : List(U8) -> {}
	check = |input| {
		depth = (input.get(0) ?? 0).to_u64() % 5
		payload = List.repeat(input.get(7) ?? 42, (input.get(1) ?? 0).to_u64() % 17)
		fixture = message(depth, payload)
		generous = { input_bytes: 4096, field_bytes: 4096, depth: 4, tags: 64, entries: 16, materialized_bytes: 256 }
		small = {
			..generous,
			depth: (input.get(2) ?? 0).to_u64() % 6,
			tags: (input.get(5) ?? 0).to_u64() % 16,
			entries: (input.get(3) ?? 0).to_u64() % 12,
			materialized_bytes: (input.get(4) ?? 0).to_u64(),
			field_bytes: (input.get(6) ?? 0).to_u64(),
		}
		for limits in [generous, small] {
			actual = read_fixture(fixture, limits)
			expected = model(fixture.steps, limits)
			if actual != expected {
				crash "nested wire result differs from cumulative budget model"
			}
		}
		{}
	}
}

Step : [Enter(U64), Leaf(List(U8)), Leave]

Fixture : { bytes : List(U8), steps : List(Step) }

# Each level has leaves before and after its child. A refund on leaving the
# child therefore changes the acceptance of subsequent sibling values.
message : U64, List(U8) -> Fixture
message = |depth, payload| {
	leaf = framed(1, payload)
	if depth == 0 {
		{ bytes: leaf.concat(leaf), steps: [Leaf(payload), Leaf(payload)] }
	} else {
		child = message(depth - 1, payload)
		{
			bytes: leaf.concat(framed(2, child.bytes)).concat(leaf),
			steps: [Leaf(payload), Enter(child.bytes.len())].concat(child.steps).concat([Leave, Leaf(payload)]),
		}
	}
}

framed : U8, List(U8) -> List(U8)
framed = |number, payload| [number * 8 + 2].concat(length_bytes(payload.len())).concat(payload)

# Independent arithmetic encoding for the generated fixture's small lengths.
length_bytes : U64 -> List(U8)
length_bytes = |length| {
	var $length = length
	var $bytes = []
	while $length >= 128 {
		$bytes = $bytes.append(($length % 128 + 128).to_u8_wrap())
		$length = $length / 128
	}
	$bytes.append($length.to_u8_wrap())
}

model : List(Step), ProtobufWire.Limits -> Try({}, ProtobufWire.Error)
model = |steps, limits| {
	var $tags = 0.U64
	var $entries = 0.U64
	var $materialized = 0.U64
	var $depth = 0.U64
	for step in steps {
		if step != Leave {
			if $tags == limits.tags {
				return Err(TagLimit)
			}
			$tags = $tags + 1
		}
		match step {
			Enter(length) => {
				if length > limits.field_bytes {
					return Err(FieldLimit)
				}
				if $depth == limits.depth {
					return Err(DepthLimit)
				}
				$depth = $depth + 1
			}
			Leaf(payload) => {
				if $entries == limits.entries {
					return Err(EntryLimit)
				}
				$entries = $entries + 1
				if payload.len() > limits.field_bytes {
					return Err(FieldLimit)
				}
				$materialized = $materialized + payload.len()
				if $materialized > limits.materialized_bytes {
					return Err(MaterializationLimit)
				}
			}
			Leave => {
				$depth = $depth - 1
			}
		}
	}
	Ok({})
}

read_fixture : Fixture, ProtobufWire.Limits -> Try({}, ProtobufWire.Error)
read_fixture = |fixture, limits| {
	var $reader = ProtobufWire.new_reader(fixture.bytes, limits)?
	var $parents = []
	for step in fixture.steps {
		if step != Leave {
			(field, after) = ProtobufWire.read_tag($reader)?
			number = match step {
				Enter(_) => 2
				_ => 1
			}
			if field != { number, kind: Bytes } {
				crash "nested wire tag mismatch"
			}
			$reader = after
		}
		match step {
			Enter(length) => {
				before = ProtobufWire.remaining($reader)
				$reader = ProtobufWire.enter_message($reader)?
				if ProtobufWire.remaining($reader) != length {
					crash "child message boundary mismatch"
				}
				if ProtobufWire.leave_message($reader) != Err(UnfinishedMessage) {
					crash "unfinished child was allowed to leave"
				}
				$parents = $parents.append(before - length_bytes(length).len() - length)
			}
			Leaf(payload) => {
				$reader = ProtobufWire.reserve($reader, 1, 0)?
				before = ProtobufWire.remaining($reader)
				(value, after) = ProtobufWire.read_bytes($reader)?
				if value != payload {
					crash "nested wire payload mismatch"
				}
				if ProtobufWire.remaining(after) != before - length_bytes(payload.len()).len() - payload.len() {
					crash "nested payload cursor mismatch"
				}
				$reader = after
			}
			Leave => {
				if ProtobufWire.remaining($reader) != 0 {
					crash "child message was not fully consumed"
				}
				if ProtobufWire.read_varint($reader) != Err(Truncated) {
					crash "child read escaped into parent"
				}
				$reader = ProtobufWire.leave_message($reader)?
				if ProtobufWire.remaining($reader) != ($parents.last() ?? 0) {
					crash "parent boundary was not restored"
				}
				$parents = $parents.drop_last(1)
			}
		}
	}
	if ProtobufWire.remaining($reader) != 0 or !$parents.is_empty() {
		crash "nested message traversal incomplete"
	}
	Ok({})
}

# Two nesting levels contain six leaves and eight tags. These controls exercise
# the nearest lower, exact, and upper bounds for each shared counter.
expect {
	for depth in [1.U8, 2, 3] {
		ScopeFuzz.check([2, 2, depth, 6, 12, 8, 255])
	}
	for entries in [5.U8, 6, 7] {
		ScopeFuzz.check([2, 2, 2, entries, 12, 8, 255])
	}
	for bytes in [11.U8, 12, 13] {
		ScopeFuzz.check([2, 2, 2, 6, bytes, 8, 255])
	}
	for tags in [7.U8, 8, 9] {
		ScopeFuzz.check([2, 2, 2, 6, 12, tags, 255])
	}
	Bool.True
}

# Empty leaf values still consume entries and tags; zero budgets can reject
# them without materialization. The largest generated shape spans a two-byte length.
expect {
	ScopeFuzz.check([4, 16, 4, 10, 160, 14, 255])
	ScopeFuzz.check([4, 0, 4, 10, 0, 14, 255])
	ScopeFuzz.check([])
	Bool.True
}
