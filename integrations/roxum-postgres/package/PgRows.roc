import PgProtocol

## The format that decodes query results into a Roc type through
## `parser_for`: a list of records whose fields match the columns by name.
## A NULL column is a missing field, so a `Try(T, [Missing])` field holds
## `Err(Missing)`; a column the record does not have is an error. Errors
## name the row and column but never the value.
PgRows := [Default].{
	## What is being decoded: the rows, one row's columns, or one value.
	Node := [
		Array(List(PgRows.Node)),
		Record(List((Str, PgRows.Node))),
		Text(List(U8)),
		Byte(U8),
	]

	Frame : [
		Value({ path : Str, node : PgRows.Node }),
		Entries({ path : Str, entries : List((Str, PgRows.Node)) }),
		Items({ path : Str, index : U64, items : List(PgRows.Node) }),
	]

	State := { stack : List(PgRows.Frame) }

	## The rows of a result, from its column names and text values.
	rows : List(Str), List(List(PgProtocol.Text)) -> PgRows.Node
	rows = |columns, values|
		Array(
			values.map(
				|row| {
					var $entries = []
					var $index = 0
					for value in row {
						name = match columns.get($index) {
							Ok(column_name) => column_name
							Err(_) => break
						}
						$index = $index + 1
						match value {
							Value(bytes) => { $entries = $entries.append((name, PgRows.Node.Text(bytes))) }
							Null => {}
						}
					}
					PgRows.Node.Record($entries)
				},
			),
		)

	decode : PgRows.Node -> Try(a, [PostgresDecodeFailed(Str), ..errs])
		where [
			a.parser_for : PgRows -> (PgRows.State -> Try({ value : a, rest : PgRows.State }, [PostgresDecodeFailed(Str), ..errs])),
		]
	decode = |node| {
		Shape : a
		parse_shape = Shape.parser_for(PgRows.Default)
		parsed = parse_shape(PgRows.State.{ stack: [Value({ path: "", node })] })?
		Ok(parsed.value)
	}

	rename_field : PgRows, Str -> Str
	rename_field = |_, name| name

	invalid_value : PgRows, PgRows.State -> [PostgresDecodeFailed(Str)]
	invalid_value = |_, state| failure(top_path(state), "invalid value")

	parse_str : PgRows, PgRows.State -> Try({ value : Str, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_str = |_, state| {
		(next, rest) = take_value(state)?
		match next.node {
			Text(bytes) =>
				match Str.from_utf8(bytes) {
					Ok(value) => Ok({ value, rest })
					Err(_) => Err(failure(next.path, "not UTF-8"))
				}
			_ => Err(failure(next.path, "expected text"))
		}
	}

	parse_bool : PgRows, PgRows.State -> Try({ value : Bool, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_bool = |_, state| {
		(next, rest) = take_value(state)?
		match next.node {
			Text(['t']) => Ok({ value: Bool.True, rest })
			Text(['f']) => Ok({ value: Bool.False, rest })
			_ => Err(failure(next.path, "expected a boolean"))
		}
	}

	parse_u8 : PgRows, PgRows.State -> Try({ value : U8, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_u8 = |_, state| {
		(next, rest) = take_value(state)?
		match next.node {
			Byte(value) => Ok({ value, rest })
			_ => number(next, rest, U8.from_str)
		}
	}

	parse_i8 : PgRows, PgRows.State -> Try({ value : I8, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_i8 = |_, state| take_number(state, I8.from_str)

	parse_u16 : PgRows, PgRows.State -> Try({ value : U16, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_u16 = |_, state| take_number(state, U16.from_str)

	parse_i16 : PgRows, PgRows.State -> Try({ value : I16, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_i16 = |_, state| take_number(state, I16.from_str)

	parse_u32 : PgRows, PgRows.State -> Try({ value : U32, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_u32 = |_, state| take_number(state, U32.from_str)

	parse_i32 : PgRows, PgRows.State -> Try({ value : I32, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_i32 = |_, state| take_number(state, I32.from_str)

	parse_u64 : PgRows, PgRows.State -> Try({ value : U64, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_u64 = |_, state| take_number(state, U64.from_str)

	parse_i64 : PgRows, PgRows.State -> Try({ value : I64, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_i64 = |_, state| take_number(state, I64.from_str)

	parse_u128 : PgRows, PgRows.State -> Try({ value : U128, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_u128 = |_, state| take_number(state, U128.from_str)

	parse_i128 : PgRows, PgRows.State -> Try({ value : I128, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_i128 = |_, state| take_number(state, I128.from_str)

	## `numeric` columns; exact, unlike the float types.
	parse_dec : PgRows, PgRows.State -> Try({ value : Dec, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_dec = |_, state| take_number(state, Dec.from_str)

	parse_f64 : PgRows, PgRows.State -> Try({ value : F64, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_f64 = |_, state| take_number(state, float_from_str)

	parse_f32 : PgRows, PgRows.State -> Try({ value : F32, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_f32 = |format, state| {
		parsed = PgRows.parse_f64(format, state)?
		Ok({ value: parsed.value.to_f32_wrap(), rest: parsed.rest })
	}

	## The rows, or the bytes of a `bytea` column (`\x` and hex digits) as
	## a `List(U8)`.
	parse_list_start : PgRows, PgRows.State -> Try([Counted({ len : U64, rest : PgRows.State }), Uncounted(PgRows.State)], [PostgresDecodeFailed(Str)])
	parse_list_start = |_, state| {
		(next, rest) = take_value(state)?
		items = match next.node {
			Array(nodes) => nodes
			Text(bytes) =>
				match hex_bytes(bytes) {
					Ok(decoded) => decoded.map(|byte| PgRows.Node.Byte(byte))
					Err(_) => return Err(failure(next.path, "expected bytea"))
				}
			_ => return Err(failure(next.path, "expected a list"))
		}
		Ok(Counted({ len: items.len(), rest: if items.is_empty() { rest } else { push(rest, Items({ path: next.path, index: 0, items })) } }))
	}

	parse_list_next : PgRows, PgRows.State -> Try([Item(PgRows.State), Done(PgRows.State)], [PostgresDecodeFailed(Str)])
	parse_list_next = |_, state| Err(failure(top_path(state), "internal error: uncounted list"))

	parse_list_after_item : PgRows, PgRows.State -> Try([Continue(PgRows.State), Done(PgRows.State)], [PostgresDecodeFailed(Str)])
	parse_list_after_item = |_, state| Err(failure(top_path(state), "internal error: uncounted list"))

	parse_record_start : PgRows, PgRows.State -> Try([Counted({ len : U64, rest : PgRows.State }), Uncounted(PgRows.State)], [PostgresDecodeFailed(Str)])
	parse_record_start = |_, state| {
		(next, rest) = take_value(state)?
		match next.node {
			Record(entries) =>
				Ok(Counted({ len: entries.len(), rest: if entries.is_empty() { rest } else { push(rest, Entries({ path: next.path, entries })) } }))
			_ => Err(failure(next.path, "expected a row"))
		}
	}

	parse_record_field : PgRows,
	Encoding.FieldName.FieldNames(_shape),
	PgRows.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : PgRows.State }),
			TryField({ name : Str, rest : PgRows.State }),
			TryFieldCaseless({ name : Str, rest : PgRows.State }),
			Continue(PgRows.State),
			Done(PgRows.State),
		],
		[PostgresDecodeFailed(Str)],
	)
	parse_record_field = |_, _, state| {
		(name, rest) = take_entry(state)?
		Ok(TryField({ name, rest }))
	}

	parse_record_after_field : PgRows, PgRows.State -> Try([Continue(PgRows.State), Done(PgRows.State)], [PostgresDecodeFailed(Str)])
	parse_record_after_field = |_, state| Err(failure(top_path(state), "internal error: uncounted row"))

	## A column the record has no field for: likely a misspelt alias.
	skip_record_field : PgRows, PgRows.State -> Try(PgRows.State, [PostgresDecodeFailed(Str)])
	skip_record_field = |_, state| Err(failure(top_path(state), "the type has no field for this column"))

	## A tag without a payload, from text in snake_case: `active` is `Active`.
	parse_tag_union : PgRows, Encoding.ParseTagUnionSpec(a), PgRows.State -> Try({ value : a, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
	parse_tag_union = |format, spec, state| {
		(next, rest) = take_value(state)?
		written = match next.node {
			Text(bytes) => Str.from_utf8(bytes) ?? ""
			_ => return Err(failure(next.path, "expected a variant name"))
		}
		Encoding.ParseTagUnionSpec.parse(
			spec,
			{
				tag: tag_name(written) ?? "",
				encoding: format,
				state: rest,
				start_payloads: |payload_state, count| if count == 0 { Ok(payload_state) } else { Err(failure(next.path, "variants with payloads are not supported")) },
				next_payload: |payload_state, _, _| Ok(payload_state),
				finish_payloads: |payload_state, _| Ok(payload_state),
				missing: failure(next.path, "unknown variant"),
			},
		)
	}
}

failure : Str, Str -> [PostgresDecodeFailed(Str)]
failure = |path, message| if path.is_empty() { PostgresDecodeFailed(message) } else { PostgresDecodeFailed("${path}: ${message}") }

push : PgRows.State, PgRows.Frame -> PgRows.State
push = |state, frame| PgRows.State.{ stack: state.stack.append(frame) }

replace_top : PgRows.State, Try(PgRows.Frame, [Empty]) -> PgRows.State
replace_top = |state, replacement| {
	below = state.stack.drop_last(1)
	match replacement {
		Ok(frame) => PgRows.State.{ stack: below.append(frame) }
		Err(Empty) => PgRows.State.{ stack: below }
	}
}

top_path : PgRows.State -> Str
top_path = |state|
	match state.stack.last() {
		Ok(Value({ path, .. })) => path
		Ok(Entries({ path, .. })) => path
		Ok(Items({ path, index, .. })) => item_path(path, index)
		Err(_) => ""
	}

## `row 3` for the rows, `column[3]` for the bytes of a column.
item_path : Str, U64 -> Str
item_path = |path, index| if path.is_empty() { "row ${U64.to_str(index + 1)}" } else { "${path}[${U64.to_str(index)}]" }

take_value : PgRows.State -> Try(({ path : Str, node : PgRows.Node }, PgRows.State), [PostgresDecodeFailed(Str)])
take_value = |state|
	match state.stack.last() {
		Ok(Value(next)) => Ok((next, replace_top(state, Err(Empty))))
		Ok(Items({ path, index, items })) =>
			match items.first() {
				Ok(node) => {
					rest = items.drop_first(1)
					remaining = if rest.is_empty() { Err(Empty) } else { Ok(Items({ path, index: index + 1, items: rest })) }
					Ok(({ path: item_path(path, index), node }, replace_top(state, remaining)))
				}
				Err(_) => Err(failure(path, "internal error: no item left"))
			}
		Ok(Entries({ path, .. })) => Err(failure(path, "internal error: expected a value"))
		Err(_) => Err(PostgresDecodeFailed("internal error: nothing left to decode"))
	}

take_entry : PgRows.State -> Try((Str, PgRows.State), [PostgresDecodeFailed(Str)])
take_entry = |state|
	match state.stack.last() {
		Ok(Entries({ path, entries })) =>
			match entries.first() {
				Ok((name, node)) => {
					rest = entries.drop_first(1)
					remaining = if rest.is_empty() { Err(Empty) } else { Ok(Entries({ path, entries: rest })) }
					column = if path.is_empty() { name } else { "${path}, column ${name}" }
					Ok((name, push(replace_top(state, remaining), Value({ path: column, node }))))
				}
				Err(_) => Err(failure(path, "internal error: no column left"))
			}
		_ => Err(failure(top_path(state), "internal error: expected a row"))
	}

take_number : PgRows.State, (Str -> Try(n, [BadNumStr])) -> Try({ value : n, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
take_number = |state, convert| {
	(next, rest) = take_value(state)?
	number(next, rest, convert)
}

number : { path : Str, node : PgRows.Node }, PgRows.State, (Str -> Try(n, [BadNumStr])) -> Try({ value : n, rest : PgRows.State }, [PostgresDecodeFailed(Str)])
number = |next, rest, convert|
	match next.node {
		Text(bytes) =>
			match convert(Str.from_utf8(bytes) ?? "") {
				Ok(value) => Ok({ value, rest })
				Err(_) => Err(failure(next.path, "expected a number that fits the type"))
			}
		_ => Err(failure(next.path, "expected a number"))
	}

## PostgreSQL writes infinities and NaN as words.
float_from_str : Str -> Try(F64, [BadNumStr])
float_from_str = |text|
	match text {
		"Infinity" => Ok(F64.infinity)
		"-Infinity" => Ok(-F64.infinity)
		"NaN" => Ok(F64.nan)
		_ => F64.from_str(text)
	}

## `\x` followed by pairs of hex digits.
hex_bytes : List(U8) -> Try(List(U8), [NotHex])
hex_bytes = |text| {
	if text.take_first(2) != ['\\', 'x'] or text.len() % 2 != 0 {
		return Err(NotHex)
	}
	digits = text.drop_first(2)
	var $out = List.with_capacity(digits.len() / 2)
	var $index = 0
	while $index < digits.len() {
		high = hex_digit(digits.get($index) ?? 0)?
		low = hex_digit(digits.get($index + 1) ?? 0)?
		$out = $out.append(high * 16 + low)
		$index = $index + 2
	}
	Ok($out)
}

hex_digit : U8 -> Try(U8, [NotHex])
hex_digit = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

## `read_only` to `ReadOnly`, as M15a's TOML format does.
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

text = |value| PgProtocol.Text.Value(value.to_utf8())

expect {
	node = PgRows.rows(["id", "name", "email", "active"], [[text("1"), text("ada"), Null, text("t")], [text("2"), text("bob"), text("b@x"), text("f")]])
	result : Try(List({ id : I64, name : Str, email : Try(Str, [Missing]), active : Bool }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(node)
	result == Ok([{ id: 1, name: "ada", email: Err(Missing), active: Bool.True }, { id: 2, name: "bob", email: Ok("b@x"), active: Bool.False }])
}

expect {
	node = PgRows.rows(["id", "nmae"], [[text("1"), text("ada")]])
	result : Try(List({ id : I64, name : Str }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(node)
	result == Err(PostgresDecodeFailed("row 1, column nmae: the type has no field for this column"))
}

expect {
	node = PgRows.rows(["age"], [[text("12")], [text("x")]])
	result : Try(List({ age : I32 }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(node)
	result == Err(PostgresDecodeFailed("row 2, column age: expected a number that fits the type"))
}

expect {
	node = PgRows.rows(["name"], [[Null]])
	result : Try(List({ name : Str }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(node)
	result == Err(MissingRequiredField("name"))
}

expect {
	node = PgRows.rows(["data", "price", "ratio", "state"], [[text("\\x00ff10"), text("12.50"), text("-Infinity"), text("read_only")]])
	result : Try(List({ data : List(U8), price : Dec, ratio : F64, state : [ReadOnly, ReadWrite] }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(node)
	match result {
		Ok([row]) => row.data == [0, 255, 16] and row.price == 12.5 and row.ratio == -F64.infinity and row.state == ReadOnly
		_ => Bool.False
	}
}

expect {
	result : Try(List({ id : I64 }), [PostgresDecodeFailed(Str), MissingRequiredField(Str)])
	result = PgRows.decode(PgRows.rows(["id"], []))
	result == Ok([])
}

# Pairing stops at the shorter list. Cover zero, one fewer, equal, and
# one extra value around two named columns; NULL preserves its position.
expect {
	result : Try(List({ a : Try(Str, [Missing]), b : Try(Str, [Missing]) }), [PostgresDecodeFailed(Str)])
	result = PgRows.decode(PgRows.rows(["a", "b"], [[], [text("x")], [Null, text("y")], [text("x"), text("y"), text("ignored")]]))
	result == Ok([
		{ a: Err(Missing), b: Err(Missing) },
		{ a: Ok("x"), b: Err(Missing) },
		{ a: Err(Missing), b: Ok("y") },
		{ a: Ok("x"), b: Ok("y") },
	])
}

expect {
	result : Try(List({}), [PostgresDecodeFailed(Str)])
	result = PgRows.decode(PgRows.rows([], [[text("ignored")]]))
	result == Ok([{}])
}
