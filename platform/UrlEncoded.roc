## WHATWG application/x-www-form-urlencoded parsing, shared by Query and Form.
## Input excludes the URL's leading `?`. No I/O or HTTP error mapping occurs here.
UrlEncoded :: [].{
	## A type that can be read from URL-encoded pairs: a record whose fields are
	## `Str`, a number, `Bool`, a `List` of those for a name that repeats, or a
	## `Try(_, [Missing])` for a name that may be left out. A name the record does
	## not have is ignored; a single-valued name that repeats is rejected.
	a.Parseable(errs) :
		where [
			a.parser_for : UrlEncoding -> (UrlState -> Try({ value : a, rest : UrlState }, errs)),
		]

	## Decodes `input` (see `decode`) and reads the pairs into `a`, chosen by the
	## caller's type.
	parse : List(U8), { max_bytes : U64, max_fields : U64 } -> Try(a, [TooManyBytes, TooManyFields, BadValue, ..errs])
		where [a.Parseable([TooManyBytes, TooManyFields, BadValue, ..errs])]
	parse = |input, limits| {
		pairs = match UrlEncoded.decode(input, limits) {
			Ok(decoded) => decoded
			Err(TooManyBytes) => return Err(TooManyBytes)
			Err(TooManyFields) => return Err(TooManyFields)
		}
		Shape : a
		parse_shape = Shape.parser_for(UrlEncoding.Standard)
		parsed = parse_shape(UrlState.{ groups: grouped(pairs), values: [] })?
		Ok(parsed.value)
	}

	## Reads one value, such as a path parameter, into `a`, a `Str`, number, or
	## `Bool`.
	parse_value : Str -> Try(a, [TooManyBytes, TooManyFields, BadValue, ..errs])
		where [a.Parseable([TooManyBytes, TooManyFields, BadValue, ..errs])]
	parse_value = |text| {
		Shape : a
		parse_shape = Shape.parser_for(UrlEncoding.Standard)
		parsed = parse_shape(UrlState.{ groups: [], values: [text] })?
		Ok(parsed.value)
	}

	## Ordered pairs preserve duplicate names. Empty segments are ignored; a
	## missing `=` means an empty value. Only the first `=` separates the pair.
	## `+` becomes space, valid percent escapes are decoded once, malformed
	## escapes stay literal, and invalid UTF-8 becomes U+FFFD. A BOM is retained.
	## Limits include every input byte and every nonempty segment (duplicates
	## included). Equality is allowed, zero is valid, and failure returns no
	## partial result. The byte limit is checked before parsing or allocating
	## output. It bounds encoded input, not decoded string storage: replacement
	## characters can expand invalid bytes. Callers must also bound body reception.
	decode : List(U8), { max_bytes : U64, max_fields : U64 } -> Try(List({ name : Str, value : Str }), [TooManyBytes, TooManyFields])
	decode = |input, limits| {
		if input.len().to_u64() > limits.max_bytes {
			return Err(TooManyBytes)
		}
		var $pairs = []
		var $name = []
		var $value = []
		var $in_value = Bool.False
		var $has_segment = Bool.False
		for byte in input {
			if byte == '&' {
				if $has_segment {
					$pairs = $pairs.append({ name: decode_component($name), value: decode_component($value) })
					$name = []
					$value = []
					$in_value = Bool.False
					$has_segment = Bool.False
				}
			} else {
				if !$has_segment and $pairs.len().to_u64() >= limits.max_fields {
					return Err(TooManyFields)
				}
				$has_segment = Bool.True
				if byte == '=' and !$in_value {
					$in_value = Bool.True
				} else if $in_value {
					$value = $value.append(byte)
				} else {
					$name = $name.append(byte)
				}
			}
		}
		if $has_segment {
			$pairs = $pairs.append({ name: decode_component($name), value: decode_component($value) })
		}
		Ok($pairs)
	}
}

decode_component = |bytes| {
	var $decoded = []
	var $index = 0
	while $index < bytes.len() {
		byte = byte_at(bytes, $index)
		if byte == '+' {
			$decoded = $decoded.append(' ')
		} else if byte == '%' and bytes.len() - $index >= 3 {
			match (hex_value(byte_at(bytes, $index + 1)), hex_value(byte_at(bytes, $index + 2))) {
				(Ok(high), Ok(low)) => {
					$decoded = $decoded.append(high * 16 + low)
					$index = $index + 2
				}
				_ => {
					$decoded = $decoded.append(byte)
				}
			}
		} else {
			$decoded = $decoded.append(byte)
		}
		$index = $index + 1
	}
	decode_utf8($decoded)
}

# WHATWG UTF-8 decode without BOM. Keep the native fast path for valid UTF-8.
# The pinned Roc lossy decoder groups some invalid sequences differently, so
# repair invalid input here using the Encoding Standard's continuation bounds.
decode_utf8 = |bytes| {
	match Str.from_utf8(bytes) {
		Ok(text) => return text
		Err(_) => {}
	}
	var $output = []
	var $index = 0
	while $index < bytes.len() {
		first = byte_at(bytes, $index)
		$index = $index + 1
		if first < 128 {
			$output = $output.append(first)
		} else {
			needed = if first >= 194 and first <= 223 {
				1
			} else if first >= 224 and first <= 239 {
				2
			} else if first >= 240 and first <= 244 {
				3
			} else {
				0
			}
			var $lower = if first == 224 {
				160
			} else if first == 240 {
				144
			} else {
				128
			}
			var $upper = if first == 237 {
				159
			} else if first == 244 {
				143
			} else {
				191
			}
			var $prefix = [first]
			var $seen = 0
			var $valid = needed > 0
			while $valid and $seen < needed and $index < bytes.len() {
				byte = byte_at(bytes, $index)
				if byte < $lower or byte > $upper {
					# Leave this byte for the next iteration; only the valid
					# prefix is replaced, so following ASCII is never swallowed.
					$valid = Bool.False
				} else {
					$prefix = $prefix.append(byte)
					$index = $index + 1
					$seen = $seen + 1
					$lower = 128
					$upper = 191
				}
			}
			$output = $output.concat(
				if $valid and $seen == needed {
					$prefix
				} else {
					[239, 191, 189]
				},
			)
		}
	}
	match Str.from_utf8($output) {
		Ok(text) => text
		Err(_) => crash "UrlEncoded: UTF-8 repair produced invalid bytes"
	}
}

byte_at = |bytes, index| match bytes.get(index) {
	Ok(byte) => byte
	Err(_) => crash "UrlEncoded: index outside checked bounds"
}

hex_value = |byte| {
	if byte >= '0' and byte <= '9' {
		return Ok(byte - '0')
	}
	if byte >= 'A' and byte <= 'F' {
		return Ok(byte - 'A' + 10)
	}
	if byte >= 'a' and byte <= 'f' {
		return Ok(byte - 'a' + 10)
	}
	Err(NotHex)
}

# Structure: absent pairs, empty segments, empty names/values, first `=` only.
expect UrlEncoded.decode("&&".to_utf8(), { max_bytes: 2, max_fields: 0 }) == Ok([])
expect UrlEncoded.decode("a&a=&=x&=&a=x=y&&".to_utf8(), { max_bytes: 100, max_fields: 5 }) == Ok([
	{ name: "a", value: "" },
	{ name: "a", value: "" },
	{ name: "", value: "x" },
	{ name: "", value: "" },
	{ name: "a", value: "x=y" },
])
# Decoding occurs after splitting, once, for both names and values; duplicate
# names remain in input order even when differently encoded on the wire.
expect UrlEncoded.decode("a+b=%26%3d%2B+%20&%61+b=%2520".to_utf8(), { max_bytes: 100, max_fields: 2 }) == Ok([
	{ name: "a b", value: "&=+  " },
	{ name: "a b", value: "%20" },
])
# Invalid escape classes: missing both digits, missing one, nonhex in either
# position, and a malformed escape immediately followed by a valid escape.
expect decode_component("%|%2|%G0|%0g|%%41".to_utf8()) == "%|%2|%G0|%0g|%A"
# Hex digit class boundaries and case folding.
expect decode_component("%30%39%4A%4F%4a%4f".to_utf8()) == "09JOJO"
# Unicode, NUL and BOM are data, not syntax. UTF-8 decode without BOM does not
# remove a leading BOM (unlike the BOM-sniffing decode algorithm).
expect decode_component("%EF%BB%BF%E9%B5%AC%00".to_utf8()) == "\u(FEFF)鵬\u(0)"
expect decode_component("鵬".to_utf8()) == "鵬"
# UTF-8 error classes: lone continuation, truncated sequence, noncontinuation
# after a valid prefix, overlong sequence, surrogate and above U+10FFFF.
expect decode_component([128]) == "�"
expect decode_component([226, 130]) == "�"
expect decode_component([226, 130, 65]) == "�A"
expect decode_component([192, 175]) == "��"
expect decode_component([237, 160, 128]) == "���"
expect decode_component([244, 144, 128, 128]) == "����"
expect decode_component("%FF".to_utf8()) == "�"
# Byte limit B=3: B-1, B, B+1; separators count toward the encoded byte limit.
expect UrlEncoded.decode("a=".to_utf8(), { max_bytes: 3, max_fields: 1 }) == Ok([{ name: "a", value: "" }])
expect UrlEncoded.decode("a=x".to_utf8(), { max_bytes: 3, max_fields: 1 }) == Ok([{ name: "a", value: "x" }])
expect UrlEncoded.decode("a=x&".to_utf8(), { max_bytes: 3, max_fields: 1 }) == Err(TooManyBytes)
# Field limit F=2: F-1, F, F+1. Repeated names count individually.
expect UrlEncoded.decode("a".to_utf8(), { max_bytes: 100, max_fields: 2 }) == Ok([{ name: "a", value: "" }])
expect UrlEncoded.decode("a&a".to_utf8(), { max_bytes: 100, max_fields: 2 }) == Ok([{ name: "a", value: "" }, { name: "a", value: "" }])
expect UrlEncoded.decode("a&a&a".to_utf8(), { max_bytes: 100, max_fields: 2 }) == Err(TooManyFields)
# Zero limits: empty input succeeds; the smallest nonempty byte/pair fails.
expect UrlEncoded.decode([], { max_bytes: 0, max_fields: 0 }) == Ok([])
expect UrlEncoded.decode([38], { max_bytes: 0, max_fields: 0 }) == Err(TooManyBytes)
expect UrlEncoded.decode([61], { max_bytes: 1, max_fields: 0 }) == Err(TooManyFields)

UrlState :: { groups : List({ name : Str, values : List(Str) }), values : List(Str) }

## The format derived parsers read pairs through: a record field gets all the
## values of its name, in order, wherever they stood in the input.
UrlEncoding :: [Standard].{
	rename_field : UrlEncoding, Str -> Str
	rename_field = |_, name| name

	parse_str : UrlEncoding, UrlState -> Try({ value : Str, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_str = |_, state|
		match state.values {
			[first, .. as rest] => Ok({ value: first, rest: UrlState.{ groups: state.groups, values: rest } })
			[] => Err(BadValue)
		}

	parse_bool : UrlEncoding, UrlState -> Try({ value : Bool, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_bool = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match taken.value {
			"true" => Ok({ value: Bool.True, rest: taken.rest })
			"false" => Ok({ value: Bool.False, rest: taken.rest })
			_ => Err(BadValue)
		}
	}

	parse_u8 : UrlEncoding, UrlState -> Try({ value : U8, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_u8 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match U8.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u16 : UrlEncoding, UrlState -> Try({ value : U16, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_u16 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match U16.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u32 : UrlEncoding, UrlState -> Try({ value : U32, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_u32 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match U32.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u64 : UrlEncoding, UrlState -> Try({ value : U64, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_u64 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match U64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i8 : UrlEncoding, UrlState -> Try({ value : I8, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_i8 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match I8.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i16 : UrlEncoding, UrlState -> Try({ value : I16, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_i16 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match I16.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i32 : UrlEncoding, UrlState -> Try({ value : I32, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_i32 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match I32.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i64 : UrlEncoding, UrlState -> Try({ value : I64, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_i64 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match I64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_f64 : UrlEncoding, UrlState -> Try({ value : F64, rest : UrlState }, [TooManyBytes, TooManyFields, BadValue])
	parse_f64 = |encoding, state| {
		taken = UrlEncoding.parse_str(encoding, state)?
		match F64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_list_start : UrlEncoding, UrlState -> Try([Counted({ len : U64, rest : UrlState }), Uncounted(UrlState)], [TooManyBytes, TooManyFields, BadValue])
	parse_list_start = |_, state| Ok(Counted({ len: List.len(state.values), rest: state }))

	## Never reached: a list always reports its count.
	parse_list_next : UrlEncoding, UrlState -> Try([Item(UrlState), Done(UrlState)], [TooManyBytes, TooManyFields, BadValue])
	parse_list_next = |_, state| Ok(Done(state))

	parse_list_after_item : UrlEncoding, UrlState -> Try([Continue(UrlState), Done(UrlState)], [TooManyBytes, TooManyFields, BadValue])
	parse_list_after_item = |_, state| Ok(Done(state))

	parse_record_start : UrlEncoding, UrlState -> Try([Counted({ len : U64, rest : UrlState }), Uncounted(UrlState)], [TooManyBytes, TooManyFields, BadValue])
	parse_record_start = |_, state| Ok(Uncounted(state))

	parse_record_field : UrlEncoding,
	Encoding.FieldName.FieldNames(_shape),
	UrlState -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : UrlState }),
			TryField({ name : Str, rest : UrlState }),
			TryFieldCaseless({ name : Str, rest : UrlState }),
			Continue(UrlState),
			Done(UrlState),
		],
		[TooManyBytes, TooManyFields, BadValue],
	)
	parse_record_field = |_, _fields, state|
		match state.groups {
			[] => Ok(Done(state))
			[first, .. as rest] => Ok(TryField({ name: first.name, rest: UrlState.{ groups: rest, values: first.values } }))
		}

	## A single-valued field with values left over is a name that repeated.
	parse_record_after_field : UrlEncoding, UrlState -> Try([Continue(UrlState), Done(UrlState)], [TooManyBytes, TooManyFields, BadValue])
	parse_record_after_field = |_, state|
		if List.is_empty(state.values) { Ok(Continue(state)) } else { Err(BadValue) }

	skip_record_field : UrlEncoding, UrlState -> Try(UrlState, [TooManyBytes, TooManyFields, BadValue])
	skip_record_field = |_, state| Ok(UrlState.{ groups: state.groups, values: [] })

	invalid_value : UrlEncoding, UrlState -> [TooManyBytes, TooManyFields, BadValue]
	invalid_value = |_, _| BadValue
}

## The pairs by name, in the order each name first appeared.
grouped = |pairs| {
	var $groups = []
	for pair in pairs {
		$groups = match List.find_first_index($groups, |group| group.name == pair.name) {
			Ok(index) => List.update($groups, index, |group| { name: group.name, values: List.append(group.values, pair.value) }) ?? $groups
			Err(_) => List.append($groups, { name: pair.name, values: [pair.value] })
		}
	}
	$groups
}

Search : { q : Str, page : Try(U64, [Missing]), tag : Try(List(Str), [Missing]) }

parse_search : Str -> Try(Search, _)
parse_search = |text| UrlEncoded.parse(text.to_utf8(), { max_bytes: 4096, max_fields: 16 })

# A name that repeats, in any position; left out; a repeat of a single value; a
# value of the wrong type; an unknown name; a required name left out.
expect parse_search("q=a%20b&tag=x&page=2&tag=y") == Ok({ q: "a b", page: Ok(2), tag: Ok(["x", "y"]) })
expect parse_search("q=a") == Ok({ q: "a", page: Err(Missing), tag: Err(Missing) })
expect parse_search("q=a&q=b") == Err(BadValue)
expect parse_search("q=a&page=x") == Err(BadValue)
expect parse_search("q=a&other=1") == Ok({ q: "a", page: Err(Missing), tag: Err(Missing) })
expect parse_search("page=1") == Err(MissingRequiredField("q"))

parse_limited : Str -> Try({ q : Str }, _)
parse_limited = |text| UrlEncoded.parse(text.to_utf8(), { max_bytes: 5, max_fields: 1 })

# The limits apply before reading: just under, at, and over the byte limit.
expect parse_limited("q=ab") == Ok({ q: "ab" })
expect parse_limited("q=abc") == Ok({ q: "abc" })
expect parse_limited("q=abcd") == Err(TooManyBytes)
expect parse_limited("q=a&r") == Err(TooManyFields)
