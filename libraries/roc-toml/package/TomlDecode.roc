import TomlValue

## The format that decodes a `TomlValue` tree into a Roc type through
## `parser_for`. Unknown keys are errors, and every error names the key path.
TomlDecode := [Default].{
	## What is left to decode, innermost last.
	##
	## - `Value`: one value, waiting for a parser.
	## - `Entries`: the remaining keys of a table being read as a record or a dict.
	## - `Items`: the remaining elements of an array; the next one is at `index`.
	Frame : [
		Value({ path : Str, value : TomlValue }),
		Entries({ path : Str, entries : List((Str, TomlValue)) }),
		Items({ path : Str, index : U64, items : List(TomlValue) }),
	]

	State := { stack : List(TomlDecode.Frame) }

	## Decodes a value into the type the caller asks for.
	decode : TomlValue -> Try(a, [TomlDecode(Str), ..errs])
		where [
			a.parser_for : TomlDecode -> (TomlDecode.State -> Try({ value : a, rest : TomlDecode.State }, [TomlDecode(Str), ..errs])),
		]
	decode = |value| {
		Shape : a
		parse_shape = Shape.parser_for(TomlDecode.Default)
		parsed = parse_shape(TomlDecode.State.{ stack: [Value({ path: "", value })] })?
		Ok(parsed.value)
	}

	rename_field : TomlDecode, Str -> Str
	rename_field = |_, name| name

	invalid_value : TomlDecode, TomlDecode.State -> [TomlDecode(Str)]
	invalid_value = |_, state| failure(top_path(state), "invalid value")

	parse_str : TomlDecode, TomlDecode.State -> Try({ value : Str, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_str = |_, state| {
		(next, rest) = take_value(state)?
		match next.value {
			String(text) => Ok({ value: text, rest })
			OffsetDateTime({ text, .. }) => Ok({ value: text, rest })
			LocalDateTime({ text, .. }) => Ok({ value: text, rest })
			LocalDate({ text, .. }) => Ok({ value: text, rest })
			LocalTime({ text, .. }) => Ok({ value: text, rest })
			other => Err(mismatch(next.path, "a string", other))
		}
	}

	parse_bool : TomlDecode, TomlDecode.State -> Try({ value : Bool, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_bool = |_, state| {
		(next, rest) = take_value(state)?
		match next.value {
			Boolean(value) => Ok({ value, rest })
			other => Err(mismatch(next.path, "a boolean", other))
		}
	}

	parse_u8 : TomlDecode, TomlDecode.State -> Try({ value : U8, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_u8 = |_, state| integer(state, "U8", |number| if number >= 0 and number <= 255 { Ok(number.to_u8_wrap()) } else { Err(OutOfRange) })

	parse_u16 : TomlDecode, TomlDecode.State -> Try({ value : U16, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_u16 = |_, state| integer(state, "U16", |number| if number >= 0 and number <= 65_535 { Ok(number.to_u16_wrap()) } else { Err(OutOfRange) })

	parse_u32 : TomlDecode, TomlDecode.State -> Try({ value : U32, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_u32 = |_, state| integer(state, "U32", |number| if number >= 0 and number <= 4_294_967_295 { Ok(number.to_u32_wrap()) } else { Err(OutOfRange) })

	parse_u64 : TomlDecode, TomlDecode.State -> Try({ value : U64, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_u64 = |_, state| integer(state, "U64", |number| if number >= 0 { Ok(number.to_u64_wrap()) } else { Err(OutOfRange) })

	parse_u128 : TomlDecode, TomlDecode.State -> Try({ value : U128, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_u128 = |_, state| integer(state, "U128", |number| if number >= 0 { Ok(number.to_u128_wrap()) } else { Err(OutOfRange) })

	parse_i8 : TomlDecode, TomlDecode.State -> Try({ value : I8, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_i8 = |_, state| integer(state, "I8", |number| if number >= -128 and number <= 127 { Ok(number.to_i8_wrap()) } else { Err(OutOfRange) })

	parse_i16 : TomlDecode, TomlDecode.State -> Try({ value : I16, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_i16 = |_, state| integer(state, "I16", |number| if number >= -32_768 and number <= 32_767 { Ok(number.to_i16_wrap()) } else { Err(OutOfRange) })

	parse_i32 : TomlDecode, TomlDecode.State -> Try({ value : I32, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_i32 = |_, state| integer(state, "I32", |number| if number >= -2_147_483_648 and number <= 2_147_483_647 { Ok(number.to_i32_wrap()) } else { Err(OutOfRange) })

	parse_i64 : TomlDecode, TomlDecode.State -> Try({ value : I64, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_i64 = |_, state| integer(state, "I64", |number| Ok(number))

	parse_i128 : TomlDecode, TomlDecode.State -> Try({ value : I128, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_i128 = |_, state| integer(state, "I128", |number| Ok(number.to_i128()))

	## Integers are accepted where a float is expected, as in `timeout = 30`.
	parse_f64 : TomlDecode, TomlDecode.State -> Try({ value : F64, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_f64 = |_, state| {
		(next, rest) = take_value(state)?
		match next.value {
			Float(value) => Ok({ value, rest })
			Integer(value) => Ok({ value: value.to_f64(), rest })
			other => Err(mismatch(next.path, "a float", other))
		}
	}

	parse_f32 : TomlDecode, TomlDecode.State -> Try({ value : F32, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_f32 = |format, state| {
		parsed = TomlDecode.parse_f64(format, state)?
		Ok({ value: parsed.value.to_f32_wrap(), rest: parsed.rest })
	}

	parse_list_start : TomlDecode, TomlDecode.State -> Try([Counted({ len : U64, rest : TomlDecode.State }), Uncounted(TomlDecode.State)], [TomlDecode(Str)])
	parse_list_start = |_, state| {
		(next, rest) = take_value(state)?
		match next.value {
			Array(items) => {
				after = if items.is_empty() { rest } else { push(rest, Items({ path: next.path, index: 0, items })) }
				Ok(Counted({ len: items.len(), rest: after }))
			}
			other => Err(mismatch(next.path, "an array", other))
		}
	}

	## Never called: arrays are always counted.
	parse_list_next : TomlDecode, TomlDecode.State -> Try([Item(TomlDecode.State), Done(TomlDecode.State)], [TomlDecode(Str)])
	parse_list_next = |_, state| Err(failure(top_path(state), "internal error: uncounted array"))

	parse_list_after_item : TomlDecode, TomlDecode.State -> Try([Continue(TomlDecode.State), Done(TomlDecode.State)], [TomlDecode(Str)])
	parse_list_after_item = |_, state| Err(failure(top_path(state), "internal error: uncounted array"))

	parse_record_start : TomlDecode, TomlDecode.State -> Try([Counted({ len : U64, rest : TomlDecode.State }), Uncounted(TomlDecode.State)], [TomlDecode(Str)])
	parse_record_start = |_, state| open_table(state)

	parse_record_field : TomlDecode,
	Encoding.FieldName.FieldNames(_shape),
	TomlDecode.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : TomlDecode.State }),
			TryField({ name : Str, rest : TomlDecode.State }),
			TryFieldCaseless({ name : Str, rest : TomlDecode.State }),
			Continue(TomlDecode.State),
			Done(TomlDecode.State),
		],
		[TomlDecode(Str)],
	)
	parse_record_field = |_, _, state| {
		(name, rest) = take_entry(state)?
		Ok(TryField({ name, rest }))
	}

	## Never called: tables are always counted.
	parse_record_after_field : TomlDecode, TomlDecode.State -> Try([Continue(TomlDecode.State), Done(TomlDecode.State)], [TomlDecode(Str)])
	parse_record_after_field = |_, state| Err(failure(top_path(state), "internal error: uncounted table"))

	## A key that the record does not have: a typo in a settings file should
	## stop the program, not be silently ignored.
	skip_record_field : TomlDecode, TomlDecode.State -> Try(TomlDecode.State, [TomlDecode(Str)])
	skip_record_field = |_, state| Err(failure(top_path(state), "unknown key"))

	parse_dict_start : TomlDecode, TomlDecode.State -> Try([Counted({ len : U64, rest : TomlDecode.State }), Uncounted(TomlDecode.State)], [TomlDecode(Str)])
	parse_dict_start = |_, state| open_table(state)

	parse_dict_next : TomlDecode, TomlDecode.State -> Try([Entry(TomlDecode.State), Done(TomlDecode.State)], [TomlDecode(Str)])
	parse_dict_next = |_, state| Err(failure(top_path(state), "internal error: uncounted table"))

	parse_dict_after_key : TomlDecode, TomlDecode.State -> Try(TomlDecode.State, [TomlDecode(Str)])
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : TomlDecode, TomlDecode.State -> Try([Continue(TomlDecode.State), Done(TomlDecode.State)], [TomlDecode(Str)])
	parse_dict_after_entry = |_, state| Err(failure(top_path(state), "internal error: uncounted table"))

	parse_key_str : TomlDecode, TomlDecode.State -> Try({ value : Str, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_key_str = |_, state| {
		(name, rest) = take_entry(state)?
		Ok({ value: name, rest })
	}

	## Tags are written in snake_case: `ReadOnly` is `"read_only"`. A tag
	## without a payload is a string, as in `level = "info"`. A tag with
	## payloads is a table with one key, as in `mode = { fixed = 3 }`; several
	## payloads are an array.
	parse_tag_union : TomlDecode, Encoding.ParseTagUnionSpec(a), TomlDecode.State -> Try({ value : a, rest : TomlDecode.State }, [TomlDecode(Str)])
	parse_tag_union = |format, spec, state| {
		(next, rest) = take_value(state)?
		unknown = failure(next.path, "unknown variant")
		match next.value {
			String(written) => {
				tag = tag_name(written) ?? ""
				Encoding.ParseTagUnionSpec.parse(
					spec,
					{
						tag,
						encoding: format,
						state: rest,
						start_payloads: |payload_state, count| if count == 0 { Ok(payload_state) } else { Err(failure(next.path, "variant ${written} needs a payload")) },
						next_payload: |payload_state, _, _| Ok(payload_state),
						finish_payloads: |payload_state, _| Ok(payload_state),
						missing: unknown,
					},
				)
			}
			Table([(written, payload)]) => {
				tag = tag_name(written) ?? ""
				path = join_key(next.path, written)
				Encoding.ParseTagUnionSpec.parse(
					spec,
					{
						tag,
						encoding: format,
						state: push(rest, Value({ path, value: payload })),
						start_payloads: |payload_state, count|
							if count == 0 {
								Err(failure(path, "variant ${written} takes no payload; write it as a string"))
							} else if count == 1 {
								Ok(payload_state)
							} else {
								match take_value(payload_state)? {
									({ value: Array(items), .. }, after) if items.len() == count => Ok(push(after, Items({ path, index: 0, items })))
									_ => Err(failure(path, "variant ${written} needs an array of ${count.to_str()} payloads"))
								}
							},
						next_payload: |payload_state, _, _| Ok(payload_state),
						finish_payloads: |payload_state, _| Ok(payload_state),
						missing: unknown,
					},
				)
			}
			other => Err(mismatch(next.path, "a variant name", other))
		}
	}
}

## `read_only` to `ReadOnly`: lowercase words of letters and digits joined by
## single underscores, each word starting with a letter. Anything else, such
## as `ReadOnly` or `read__only`, is not a tag name.
tag_name : Str -> Try(Str, [NotTagName])
tag_name = |written| {
	var $out = []
	var $word_start = Bool.True
	for byte in written.to_utf8() {
		if byte == '_' {
			if $word_start {
				return Err(NotTagName)
			}
			$word_start = Bool.True
		} else if byte >= 'a' and byte <= 'z' {
			$out = $out.append(if $word_start { byte - 32 } else { byte })
			$word_start = Bool.False
		} else if byte >= '0' and byte <= '9' and !$word_start {
			$out = $out.append(byte)
		} else {
			return Err(NotTagName)
		}
	}
	if $word_start {
		Err(NotTagName)
	} else {
		Str.from_utf8($out).map_err(|_| NotTagName)
	}
}

## ---- the stack ----------------------------------------------------------

failure : Str, Str -> [TomlDecode(Str)]
failure = |path, message|
	if path.is_empty() {
		TomlDecode(message)
	} else {
		TomlDecode("${path}: ${message}")
	}

mismatch : Str, Str, TomlValue -> [TomlDecode(Str)]
mismatch = |path, expected, found| failure(path, "expected ${expected}, found ${found.kind()}")

join_key : Str, Str -> Str
join_key = |path, key| if path.is_empty() { key } else { "${path}.${key}" }

push : TomlDecode.State, TomlDecode.Frame -> TomlDecode.State
push = |state, frame| TomlDecode.State.{ stack: state.stack.append(frame) }

## Replaces the top frame, or drops it when `replacement` is empty.
replace_top : TomlDecode.State, Try(TomlDecode.Frame, [Empty]) -> TomlDecode.State
replace_top = |state, replacement| {
	below = state.stack.drop_last(1)
	match replacement {
		Ok(frame) => TomlDecode.State.{ stack: below.append(frame) }
		Err(Empty) => TomlDecode.State.{ stack: below }
	}
}

top_path : TomlDecode.State -> Str
top_path = |state|
	match state.stack.last() {
		Ok(Value({ path, .. })) => path
		Ok(Entries({ path, .. })) => path
		Ok(Items({ path, index, .. })) => "${path}[${U64.to_str(index)}]"
		Err(_) => ""
	}

## The next value: a pending value, or the next element of an array.
take_value : TomlDecode.State -> Try(({ path : Str, value : TomlValue }, TomlDecode.State), [TomlDecode(Str)])
take_value = |state|
	match state.stack.last() {
		Ok(Value(next)) => Ok((next, replace_top(state, Err(Empty))))
		Ok(Items({ path, index, items })) =>
			match items.first() {
				Ok(value) => {
					rest = items.drop_first(1)
					remaining = if rest.is_empty() { Err(Empty) } else { Ok(Items({ path, index: index + 1, items: rest })) }
					Ok(({ path: "${path}[${index.to_str()}]", value }, replace_top(state, remaining)))
				}
				Err(_) => Err(failure(path, "internal error: no array element left"))
			}
		Ok(Entries({ path, .. })) => Err(failure(path, "internal error: expected a value"))
		Err(_) => Err(TomlDecode("internal error: nothing left to decode"))
	}

## The next key of the table being read; its value becomes pending.
take_entry : TomlDecode.State -> Try((Str, TomlDecode.State), [TomlDecode(Str)])
take_entry = |state|
	match state.stack.last() {
		Ok(Entries({ path, entries })) =>
			match entries.first() {
				Ok((key, value)) => {
					rest = entries.drop_first(1)
					remaining = if rest.is_empty() { Err(Empty) } else { Ok(Entries({ path, entries: rest })) }
					Ok((key, push(replace_top(state, remaining), Value({ path: join_key(path, key), value }))))
				}
				Err(_) => Err(failure(path, "internal error: no key left"))
			}
		_ => Err(failure(top_path(state), "internal error: expected a table"))
	}

open_table : TomlDecode.State -> Try([Counted({ len : U64, rest : TomlDecode.State }), Uncounted(TomlDecode.State)], [TomlDecode(Str)])
open_table = |state| {
	(next, rest) = take_value(state)?
	match next.value {
		Table(entries) =>
			if entries.is_empty() {
				Ok(Counted({ len: 0, rest }))
			} else {
				Ok(Counted({ len: entries.len(), rest: push(rest, Entries({ path: next.path, entries })) }))
			}
		other => Err(mismatch(next.path, "a table", other))
	}
}

integer : TomlDecode.State, Str, (I64 -> Try(n, [OutOfRange])) -> Try({ value : n, rest : TomlDecode.State }, [TomlDecode(Str)])
integer = |state, type_name, convert| {
	(next, rest) = take_value(state)?
	match next.value {
		Integer(number) =>
			match convert(number) {
				Ok(value) => Ok({ value, rest })
				Err(OutOfRange) => Err(failure(next.path, "the integer does not fit in ${type_name}"))
			}
		other => Err(mismatch(next.path, "an integer", other))
	}
}

## ---- tests ------------------------------------------------------------

expect {
	value : TomlValue
	value = Table([("name", String("roxum")), ("port", Integer(8080)), ("ratio", Integer(2)), ("debug", Boolean(Bool.False))])
	result : Try({ name : Str, port : U16, ratio : F64, debug : Bool }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Ok({ name: "roxum", port: 8080, ratio: 2.0, debug: Bool.False })
}

expect {
	value : TomlValue
	value = Table([("db", Table([("hosts", Array([String("a"), String("b")])), ("pool", Table([("size", Integer(4))]))]))])
	result : Try({ db : { hosts : List(Str), pool : { size : U32 } } }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Ok({ db: { hosts: ["a", "b"], pool: { size: 4 } } })
}

expect {
	value : TomlValue
	value = Table([("db", Table([("host", String("a")), ("hots", String("b"))]))])
	result : Try({ db : { host : Str } }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Err(TomlDecode("db.hots: unknown key"))
}

expect {
	value : TomlValue
	value = Table([("servers", Array([Table([("port", Integer(1))]), Table([("port", String("x"))])]))])
	result : Try({ servers : List({ port : U16 }) }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Err(TomlDecode("servers[1].port: expected an integer, found a string"))
}

expect {
	value : TomlValue
	value = Table([("port", Integer(70000))])
	result : Try({ port : U16 }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Err(TomlDecode("port: the integer does not fit in U16"))
}

expect {
	value : TomlValue
	value = Table([("name", String("x"))])
	result : Try({ name : Str, port : U16 }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Err(MissingRequiredField("port"))
}

expect {
	value : TomlValue
	value = Table([("name", String("x"))])
	result : Try({ name : Str, port : Try(U16, [Missing]) }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Ok({ name: "x", port: Err(Missing) })
}

expect {
	value : TomlValue
	value = Table([("level", String("warn")), ("mode", Table([("fixed", Integer(3))])), ("pair", Table([("both_of", Array([Integer(1), String("b")]))])), ("http", String("http2_only"))])
	result : Try({ level : [Info, Warn], mode : [Auto, Fixed(U64)], pair : [BothOf(U8, Str)], http : [Http1, Http2Only] }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Ok({ level: Warn, mode: Fixed(3), pair: BothOf(1, "b"), http: Http2Only })
}

expect {
	value : TomlValue
	value = Table([("level", String("loud"))])
	result : Try({ level : [Info, Warn] }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Err(TomlDecode("level: unknown variant"))
}

expect {
	value : TomlValue
	value = Table([("upstreams", Table([("a", Table([("url", String("http://a"))])), ("b", Table([("url", String("http://b"))]))]))])
	result : Try({ upstreams : Dict(Str, { url : Str }) }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	match result {
		Ok({ upstreams }) => upstreams.len() == 2 and upstreams.get("b") == Ok({ url: "http://b" })
		Err(_) => Bool.False
	}
}

expect {
	value : TomlValue
	value = Table([("at", LocalDate({ date: { year: 2026, month: 10, day: 10 }, text: "2026-10-10" })), ("empty", Table([])), ("none", Array([]))])
	result : Try({ at : Str, empty : {}, none : List(U8) }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = TomlDecode.decode(value)
	result == Ok({ at: "2026-10-10", empty: {}, none: [] })
}

# Only the snake_case form names a tag.
expect {
	unknown = |written| {
		value : TomlValue
		value = Table([("mode", String(written))])
		result : Try({ mode : [ReadOnly, ReadWrite] }, [TomlDecode(Str), MissingRequiredField(Str)])
		result = TomlDecode.decode(value)
		result == Err(TomlDecode("mode: unknown variant"))
	}
	unknown("ReadOnly") and unknown("readonly") and unknown("read__only") and unknown("_read_only") and unknown("read_only_") and unknown("read_1") and unknown("")
}

expect TomlDecode.decode(TomlValue.Table([("mode", String("read_write"))])) == Ok({ mode: ReadWrite })
