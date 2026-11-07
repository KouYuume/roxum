## multipart/form-data, as pure functions over bytes: an
## incremental parser that takes a body in parts cut anywhere, and a reader of a
## whole body into a record. `Multipart` and `Extract.Multipart` connect these to
## requests. A field's `filename` is what the client wrote: never use it as a path.
MultipartBody :: [].{
	## Limits on one body. Equality is allowed.
	Limits := {
		max_fields : U64 ?? 128,
		max_header_bytes : U64 ?? 8192,
		max_field_bytes : U64 ?? 18_446_744_073_709_551_615,
	}

	## The headers of one field.
	FieldHead := {
		name : Str,
		filename : Try(Str, [NoFilename]),
		content_type : Try(Str, [NoContentType]),
	}.{
		is_eq : _
	}

	## An uploaded field, read whole.
	Upload := {
		filename : Try(Str, [NoFilename]),
		content_type : Try(Str, [NoContentType]),
		bytes : List(U8),
	}.{
		is_eq : _

		parser_for : MultipartEncoding -> (MultipartState -> Try({ value : MultipartBody.Upload, rest : MultipartState }, [BadValue]))
		parser_for = |_encoding| |state|
			match state.values {
				[first, .. as rest] => Ok({
					value: MultipartBody.Upload.{ filename: first.head.filename, content_type: first.head.content_type, bytes: first.bytes },
					rest: MultipartState.{ groups: state.groups, values: rest },
				})
				[] => Err(BadValue)
			}
	}

	## A type that can be read from a body: a record whose fields are `Str`, a
	## number, `Bool`, `Upload`, a `List` of those for a name that repeats, or a
	## `Try(_, [Missing])` for a name that may be left out.
	a.Parseable(errs) :
		where [
			a.parser_for : MultipartEncoding -> (MultipartState -> Try({ value : a, rest : MultipartState }, errs)),
		]

	## What the parser has seen so far of a body.
	Parser := {
		delimiter : List(U8),
		buffer : List(U8),
		phase : [Preamble, AfterDelimiter, Headers, Body, Epilogue],
		fields : U64,
		field_bytes : U64,
		limits : MultipartBody.Limits,
	}

	## The boundary of a `multipart/form-data` Content-Type value.
	boundary : List(U8) -> Try(List(U8), [NotMultipart])
	boundary = |value| {
		text = Str.from_utf8_lossy(value)
		pieces = Str.split_on(text, ";")
		media = ascii_lower(Str.trim(List.first(pieces) ?? ""))
		if media != "multipart/form-data" {
			return Err(NotMultipart)
		}
		for (name, parameter) in parameters(value) {
			if name == "boundary" and !List.is_empty(parameter) and List.len(parameter) <= 70 {
				return Ok(parameter)
			}
		}
		Err(NotMultipart)
	}

	new : List(U8), MultipartBody.Limits -> MultipartBody.Parser
	new = |boundary_bytes, limits| MultipartBody.Parser.{
		delimiter: List.concat("\r\n--".to_utf8(), boundary_bytes),
		# The first delimiter has no line before it.
		buffer: "\r\n".to_utf8(),
		phase: Preamble,
		fields: 0,
		field_bytes: 0,
		limits,
	}

	## Takes the next part of the body, cut anywhere, and returns what it
	## completed, in order: the head of a field, then the field's bytes in parts.
	feed : MultipartBody.Parser, List(U8) -> Try({ parser : MultipartBody.Parser, events : List([Field(MultipartBody.FieldHead), Data(List(U8))]) }, [Invalid, TooLarge])
	feed = |parser, bytes| advance({ ..parser, buffer: List.concat(parser.buffer, bytes) }, [])

	## Checks that the body ended at its closing delimiter.
	finish : MultipartBody.Parser -> Try({}, [Invalid, TooLarge])
	finish = |parser|
		match parser.phase {
			Epilogue => Ok({})
			Preamble | AfterDelimiter | Headers | Body => Err(Invalid)
		}

	## The fields of a whole body, in order.
	parts : List(U8), List(U8), MultipartBody.Limits -> Try(List({ head : MultipartBody.FieldHead, bytes : List(U8) }), [Invalid, TooLarge])
	parts = |body, boundary_bytes, limits| {
		fed = MultipartBody.feed(MultipartBody.new(boundary_bytes, limits), body)?
		MultipartBody.finish(fed.parser)?
		# The current field is kept apart from the finished ones. Replacing the last of
		# the list reads freed memory with the pinned compiler speed backend.
		var $parts = []
		var $current = Err(NoField)
		for event in fed.events {
			match event {
				Field(head) => {
					match $current {
						Ok(field) => { $parts = List.append($parts, field) }
						Err(NoField) => {}
					}
					$current = Ok({ head, bytes: [] })
				}
				Data(bytes) => {
					$current = match $current {
						Ok(field) => Ok({ head: field.head, bytes: List.concat(field.bytes, bytes) })
						Err(NoField) => Err(NoField)
					}
				}
			}
		}
		match $current {
			Ok(field) => Ok(List.append($parts, field))
			Err(NoField) => Ok($parts)
		}
	}

	## Reads a whole body into `a`, chosen by the caller's type.
	parse : List(U8), List(U8), MultipartBody.Limits -> Try(a, [Invalid, TooLarge, BadValue, ..errs])
		where [a.Parseable([Invalid, TooLarge, BadValue, ..errs])]
	parse = |body, boundary_bytes, limits| {
		fields = match MultipartBody.parts(body, boundary_bytes, limits) {
			Ok(found) => found
			Err(Invalid) => return Err(Invalid)
			Err(TooLarge) => return Err(TooLarge)
		}
		Shape : a
		parse_shape = Shape.parser_for(MultipartEncoding.Standard)
		parsed = parse_shape(MultipartState.{ groups: grouped(fields), values: [] })?
		Ok(parsed.value)
	}
}

MultipartState :: { groups : List({ name : Str, values : List({ head : MultipartBody.FieldHead, bytes : List(U8) }) }), values : List({ head : MultipartBody.FieldHead, bytes : List(U8) }) }

## The format derived parsers read fields through.
MultipartEncoding :: [Standard].{
	rename_field : MultipartEncoding, Str -> Str
	rename_field = |_, name| name

	parse_str : MultipartEncoding, MultipartState -> Try({ value : Str, rest : MultipartState }, [BadValue])
	parse_str = |_, state|
		match state.values {
			[first, .. as rest] =>
				match Str.from_utf8(first.bytes) {
					Ok(value) => Ok({ value, rest: MultipartState.{ groups: state.groups, values: rest } })
					Err(_) => Err(BadValue)
				}
			[] => Err(BadValue)
		}

	parse_bool : MultipartEncoding, MultipartState -> Try({ value : Bool, rest : MultipartState }, [BadValue])
	parse_bool = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match taken.value {
			"true" => Ok({ value: Bool.True, rest: taken.rest })
			"false" => Ok({ value: Bool.False, rest: taken.rest })
			_ => Err(BadValue)
		}
	}

	parse_u8 : MultipartEncoding, MultipartState -> Try({ value : U8, rest : MultipartState }, [BadValue])
	parse_u8 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match U8.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u16 : MultipartEncoding, MultipartState -> Try({ value : U16, rest : MultipartState }, [BadValue])
	parse_u16 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match U16.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u32 : MultipartEncoding, MultipartState -> Try({ value : U32, rest : MultipartState }, [BadValue])
	parse_u32 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match U32.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_u64 : MultipartEncoding, MultipartState -> Try({ value : U64, rest : MultipartState }, [BadValue])
	parse_u64 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match U64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i8 : MultipartEncoding, MultipartState -> Try({ value : I8, rest : MultipartState }, [BadValue])
	parse_i8 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match I8.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i16 : MultipartEncoding, MultipartState -> Try({ value : I16, rest : MultipartState }, [BadValue])
	parse_i16 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match I16.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i32 : MultipartEncoding, MultipartState -> Try({ value : I32, rest : MultipartState }, [BadValue])
	parse_i32 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match I32.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_i64 : MultipartEncoding, MultipartState -> Try({ value : I64, rest : MultipartState }, [BadValue])
	parse_i64 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match I64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_f64 : MultipartEncoding, MultipartState -> Try({ value : F64, rest : MultipartState }, [BadValue])
	parse_f64 = |encoding, state| {
		taken = MultipartEncoding.parse_str(encoding, state)?
		match F64.from_str(taken.value) {
			Ok(value) => Ok({ value, rest: taken.rest })
			Err(_) => Err(BadValue)
		}
	}

	parse_list_start : MultipartEncoding, MultipartState -> Try([Counted({ len : U64, rest : MultipartState }), Uncounted(MultipartState)], [BadValue])
	parse_list_start = |_, state| Ok(Counted({ len: List.len(state.values), rest: state }))

	## Never reached: a list always reports its count.
	parse_list_next : MultipartEncoding, MultipartState -> Try([Item(MultipartState), Done(MultipartState)], [BadValue])
	parse_list_next = |_, state| Ok(Done(state))

	parse_list_after_item : MultipartEncoding, MultipartState -> Try([Continue(MultipartState), Done(MultipartState)], [BadValue])
	parse_list_after_item = |_, state| Ok(Done(state))

	parse_record_start : MultipartEncoding, MultipartState -> Try([Counted({ len : U64, rest : MultipartState }), Uncounted(MultipartState)], [BadValue])
	parse_record_start = |_, state| Ok(Uncounted(state))

	parse_record_field : MultipartEncoding,
	Encoding.FieldName.FieldNames(_shape),
	MultipartState -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : MultipartState }),
			TryField({ name : Str, rest : MultipartState }),
			TryFieldCaseless({ name : Str, rest : MultipartState }),
			Continue(MultipartState),
			Done(MultipartState),
		],
		[BadValue],
	)
	parse_record_field = |_, _fields, state|
		match state.groups {
			[] => Ok(Done(state))
			[first, .. as rest] => Ok(TryField({ name: first.name, rest: MultipartState.{ groups: rest, values: first.values } }))
		}

	## A single-valued field with values left over is a name that repeated.
	parse_record_after_field : MultipartEncoding, MultipartState -> Try([Continue(MultipartState), Done(MultipartState)], [BadValue])
	parse_record_after_field = |_, state|
		if List.is_empty(state.values) { Ok(Continue(state)) } else { Err(BadValue) }

	skip_record_field : MultipartEncoding, MultipartState -> Try(MultipartState, [BadValue])
	skip_record_field = |_, state| Ok(MultipartState.{ groups: state.groups, values: [] })

	invalid_value : MultipartEncoding, MultipartState -> [BadValue]
	invalid_value = |_, _| BadValue
}

grouped = |fields| {
	var $groups = []
	for field in fields {
		$groups = match List.find_first_index($groups, |group| group.name == field.head.name) {
			Ok(index) => List.update($groups, index, |group| { name: group.name, values: List.append(group.values, field) }) ?? $groups
			Err(_) => List.append($groups, { name: field.head.name, values: [field] })
		}
	}
	$groups
}

## Runs the parser as far as its buffer allows.
advance = |parser, events|
	match parser.phase {
		Preamble | Body => advance_data(parser, events)
		AfterDelimiter => advance_delimiter(parser, events)
		Headers => advance_headers(parser, events)
		Epilogue => Ok({ parser: { ..parser, buffer: [] }, events })
	}

## Looks for the delimiter. Without one, passes on all but what could be its start.
advance_data = |parser, events|
	match find(parser.buffer, parser.delimiter) {
		Found(index) => {
			with_data = emit(parser, events, List.take_first(parser.buffer, index))?
			advance({ ..with_data.parser, buffer: List.drop_first(parser.buffer, index + List.len(parser.delimiter)), phase: AfterDelimiter }, with_data.events)
		}
		NotFound => {
			most = List.len(parser.delimiter) - 1
			kept = if List.len(parser.buffer) < most { List.len(parser.buffer) } else { most }
			ready = List.len(parser.buffer) - kept
			with_data = emit(parser, events, List.take_first(parser.buffer, ready))?
			Ok({ parser: { ..with_data.parser, buffer: List.drop_first(parser.buffer, ready) }, events: with_data.events })
		}
	}

## The bytes of the current field, counted against its limit. Before the first
## delimiter they are the preamble, which is dropped.
emit = |parser, events, bytes|
	if parser.phase == Preamble or List.is_empty(bytes) {
		Ok({ parser, events })
	} else {
		total = parser.field_bytes + List.len(bytes)
		if total > parser.limits.max_field_bytes {
			Err(TooLarge)
		} else {
			Ok({ parser: { ..parser, field_bytes: total }, events: List.append(events, Data(bytes)) })
		}
	}

## After a delimiter: `--` ends the body; otherwise optional padding and a line end.
advance_delimiter = |parser, events| {
	buffer = parser.buffer
	if List.len(buffer) < 2 {
		return Ok({ parser, events })
	}
	if List.take_first(buffer, 2) == "--".to_utf8() {
		return Ok({ parser: { ..parser, buffer: [], phase: Epilogue }, events })
	}
	padding = count_padding(buffer)
	if padding > parser.limits.max_header_bytes {
		return Err(TooLarge)
	}
	after = List.drop_first(buffer, padding)
	if List.len(after) < 2 {
		return Ok({ parser, events })
	}
	if List.take_first(after, 2) != "\r\n".to_utf8() {
		return Err(Invalid)
	}
	advance({ ..parser, buffer: List.drop_first(after, 2), phase: Headers }, events)
}

count_padding = |bytes| {
	var $count = 0
	for byte in bytes {
		if byte != ' ' and byte != '\t' { break }
		$count = $count + 1
	}
	$count
}

## A field's headers end at a blank line.
advance_headers = |parser, events| {
	if parser.fields >= parser.limits.max_fields and !List.is_empty(parser.buffer) {
		return Err(TooLarge)
	}
	match find(parser.buffer, "\r\n\r\n".to_utf8()) {
		NotFound =>
			if List.len(parser.buffer) > parser.limits.max_header_bytes {
				Err(TooLarge)
			} else {
				Ok({ parser, events })
			}
		Found(index) =>
			if index > parser.limits.max_header_bytes {
				Err(TooLarge)
			} else {
				head = parse_head(List.take_first(parser.buffer, index))?
				advance(
					{ ..parser, buffer: List.drop_first(parser.buffer, index + 4), phase: Body, fields: parser.fields + 1, field_bytes: 0 },
					List.append(events, Field(head)),
				)
			}
	}
}

parse_head = |bytes| {
	var $disposition = Err(Missing)
	var $content_type = Err(NoContentType)
	for line in Str.split_on(Str.from_utf8_lossy(bytes), "\r\n") {
		match Str.split_first(line, ":") {
			Ok({ before, after }) => {
				name = ascii_lower(Str.trim(before))
				if name == "content-disposition" {
					$disposition = Ok(Str.trim(after))
				} else if name == "content-type" {
					$content_type = Ok(Str.trim(after))
				}
			}
			Err(NotFound) => return Err(Invalid)
		}
	}
	disposition = match $disposition {
		Ok(value) => value
		Err(Missing) => return Err(Invalid)
	}
	if ascii_lower(Str.trim(List.first(Str.split_on(disposition, ";")) ?? "")) != "form-data" {
		return Err(Invalid)
	}
	found = parameters(disposition.to_utf8())
	name = match List.find_first(found, |(key, _)| key == "name") {
		Ok((_, value)) => Str.from_utf8_lossy(value)
		Err(_) => return Err(Invalid)
	}
	filename = match List.find_first(found, |(key, _)| key == "filename") {
		Ok((_, value)) => Ok(Str.from_utf8_lossy(value))
		Err(_) => Err(NoFilename)
	}
	Ok(MultipartBody.FieldHead.{ name, filename, content_type: $content_type })
}

## The `; name=value` parameters of a header value, with quoted values unescaped.
parameters = |value| {
	var $rest = skip_to_semicolon(value)
	var $found = []
	while !List.is_empty($rest) {
		after_name = take_name(List.drop_first($rest, 1))
		parsed = take_value(after_name.rest)
		if !List.is_empty(after_name.name) {
			$found = List.append($found, (ascii_lower(Str.from_utf8_lossy(after_name.name)), parsed.value))
		}
		$rest = skip_to_semicolon(parsed.rest)
	}
	$found
}

skip_to_semicolon = |bytes| {
	var $index = 0
	for byte in bytes {
		if byte == ';' { break }
		$index = $index + 1
	}
	List.drop_first(bytes, $index)
}

take_name = |bytes| {
	trimmed = List.drop_first(bytes, count_padding(bytes))
	var $index = 0
	for byte in trimmed {
		if byte == '=' or byte == ';' or byte == ' ' or byte == '\t' { break }
		$index = $index + 1
	}
	{ name: List.take_first(trimmed, $index), rest: List.drop_first(trimmed, $index) }
}

take_value = |bytes|
	match List.drop_first(bytes, count_padding(bytes)) {
		['=', .. as rest] => {
			trimmed = List.drop_first(rest, count_padding(rest))
			match trimmed {
				['"', .. as quoted] => take_quoted(quoted, [])
				_ => {
					var $index = 0
					for byte in trimmed {
						if byte == ';' or byte == ' ' or byte == '\t' { break }
						$index = $index + 1
					}
					{ value: List.take_first(trimmed, $index), rest: List.drop_first(trimmed, $index) }
				}
			}
		}
		other => { value: [], rest: other }
	}

take_quoted = |bytes, value|
	match bytes {
		[] => { value, rest: [] }
		['"', .. as rest] => { value, rest }
		['\\', escaped, .. as rest] => take_quoted(rest, List.append(value, escaped))
		[byte, .. as rest] => take_quoted(rest, List.append(value, byte))
	}

## The first index of `needle` in `haystack`.
find = |haystack, needle| {
	first = List.first(needle) ?? 0
	length = List.len(needle)
	var $index = 0
	while $index + length <= List.len(haystack) {
		if List.get(haystack, $index) == Ok(first) and List.take_first(List.drop_first(haystack, $index), length) == needle {
			return Found($index)
		}
		$index = $index + 1
	}
	NotFound
}

ascii_lower = |text| Str.from_utf8_lossy(List.map(text.to_utf8(), |byte| if byte >= 'A' and byte <= 'Z' { byte + 32 } else { byte }))

## A body with a text field, an empty field, a file, and a value that holds the
## start of the delimiter.
sample : List(U8)
sample =
	"preamble\r\n--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--B\r\nContent-Disposition: form-data; name=\"empty\"\r\n\r\n\r\n--B \t\r\nContent-Disposition: form-data; name=\"icon\"; filename=\"a\\\"b.png\"\r\nContent-Type: image/png\r\n\r\nx\r\n--Cy\r\n--\r\n--B--\r\nepilogue".to_utf8()

limits = MultipartBody.Limits.{}

## The fields a body gives when fed cut at `at`.
fields_cut_at = |body, at, boundary_bytes| {
	one = MultipartBody.feed(MultipartBody.new(boundary_bytes, limits), List.take_first(body, at))?
	two = MultipartBody.feed(one.parser, List.drop_first(body, at))?
	MultipartBody.finish(two.parser)?
	Ok(gather(List.concat(one.events, two.events)))
}

gather = |events| {
	var $text = []
	for event in events {
		match event {
			Field(head) => { $text = List.concat($text, "[${head.name}]".to_utf8()) }
			Data(bytes) => { $text = List.concat($text, bytes) }
		}
	}
	Str.from_utf8_lossy($text)
}

sample_fields = "[title]hello[empty][icon]x\r\n--Cy\r\n--"

# The result does not depend on where the body is cut: every position.
expect {
	var $at = 0
	var $all = Bool.True
	while $at <= List.len(sample) {
		$all = $all and fields_cut_at(sample, $at, "B".to_utf8()) == Ok(sample_fields)
		$at = $at + 1
	}
	$all
}

# Fed one byte at a time.
expect {
	var $parser = MultipartBody.new("B".to_utf8(), limits)
	var $events = []
	for byte in sample {
		match MultipartBody.feed($parser, [byte]) {
			Ok(fed) => {
				$parser = fed.parser
				$events = List.concat($events, fed.events)
			}
			Err(_) => crash "feed failed"
		}
	}
	MultipartBody.finish($parser) == Ok({}) and gather($events) == sample_fields
}

parsed_sample = MultipartBody.parts(sample, "B".to_utf8(), limits)

expect match parsed_sample {
	Ok([title, empty, icon]) =>
		title.bytes == "hello".to_utf8()
			and empty.bytes == []
			and icon.head.filename == Ok("a\"b.png")
			and icon.head.content_type == Ok("image/png")
			and title.head.filename == Err(NoFilename)
	_ => Bool.False
}

# The body must reach its closing delimiter.
expect MultipartBody.parts("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)
expect MultipartBody.parts("no delimiter".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)
# A field needs form-data and a name, and a line of headers needs a colon.
expect MultipartBody.parts("--B\r\nContent-Disposition: attachment; name=\"a\"\r\n\r\nx\r\n--B--".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)
expect MultipartBody.parts("--B\r\nContent-Disposition: form-data\r\n\r\nx\r\n--B--".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)
expect MultipartBody.parts("--B\r\nbad line\r\n\r\nx\r\n--B--".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)
# After the delimiter: only padding and a line end, or `--`.
expect MultipartBody.parts("--Bad\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--B--".to_utf8(), "B".to_utf8(), limits) == Err(Invalid)

field_body = |count| {
	field = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n".to_utf8()
	List.concat(List.join(List.repeat(field, count)), "--B--".to_utf8())
}

# The field limit: under, at, and over.
expect is_ok(MultipartBody.parts(field_body(1), "B".to_utf8(), MultipartBody.Limits.{ max_fields: 2 }))
expect is_ok(MultipartBody.parts(field_body(2), "B".to_utf8(), MultipartBody.Limits.{ max_fields: 2 }))
expect MultipartBody.parts(field_body(3), "B".to_utf8(), MultipartBody.Limits.{ max_fields: 2 }) == Err(TooLarge)

value_body = |text| "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n${text}\r\n--B--".to_utf8()

# The bytes of one field: under, at, and over.
expect is_ok(MultipartBody.parts(value_body("ab"), "B".to_utf8(), MultipartBody.Limits.{ max_field_bytes: 3 }))
expect is_ok(MultipartBody.parts(value_body("abc"), "B".to_utf8(), MultipartBody.Limits.{ max_field_bytes: 3 }))
expect MultipartBody.parts(value_body("abcd"), "B".to_utf8(), MultipartBody.Limits.{ max_field_bytes: 3 }) == Err(TooLarge)

head_size = Str.count_utf8_bytes("Content-Disposition: form-data; name=\"a\"")

# The bytes of a field's headers: under, at, and over.
expect is_ok(MultipartBody.parts(value_body("x"), "B".to_utf8(), MultipartBody.Limits.{ max_header_bytes: head_size + 1 }))
expect is_ok(MultipartBody.parts(value_body("x"), "B".to_utf8(), MultipartBody.Limits.{ max_header_bytes: head_size }))
expect MultipartBody.parts(value_body("x"), "B".to_utf8(), MultipartBody.Limits.{ max_header_bytes: head_size - 1 }) == Err(TooLarge)

is_ok = |result|
	match result {
		Ok(_) => Bool.True
		Err(_) => Bool.False
	}

# The boundary: from a parameter, quoted, with case, or missing.
expect MultipartBody.boundary("multipart/form-data; boundary=abc".to_utf8()) == Ok("abc".to_utf8())
expect MultipartBody.boundary("Multipart/Form-Data; charset=utf-8; boundary=\"a b\"".to_utf8()) == Ok("a b".to_utf8())
expect MultipartBody.boundary("multipart/form-data".to_utf8()) == Err(NotMultipart)
expect MultipartBody.boundary("application/json; boundary=abc".to_utf8()) == Err(NotMultipart)

Profile : { title : Str, count : Try(U64, [Missing]), icon : MultipartBody.Upload, tags : Try(List(Str), [Missing]) }

parse_profile : List(U8) -> Try(Profile, _)
parse_profile = |body| MultipartBody.parse(body, "B".to_utf8(), limits)

named = |name, value| "--B\r\nContent-Disposition: form-data; name=\"${name}\"; filename=\"${name}.txt\"\r\n\r\n${value}\r\n"

expect match parse_profile("${named("title", "t")}${named("icon", "i")}${named("tags", "a")}${named("tags", "b")}--B--".to_utf8()) {
	Ok(profile) => profile.title == "t" and profile.icon.bytes == "i".to_utf8() and profile.count == Err(Missing) and profile.tags == Ok(["a", "b"])
	Err(_) => Bool.False
}
expect parse_profile("${named("icon", "i")}--B--".to_utf8()) == Err(MissingRequiredField("title"))
expect parse_profile("${named("title", "t")}${named("title", "u")}${named("icon", "i")}--B--".to_utf8()) == Err(BadValue)
