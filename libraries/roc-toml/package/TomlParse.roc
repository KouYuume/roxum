import TomlValue

## TOML 1.0 text to a `TomlValue` tree. Errors name the line.
TomlParse := [].{
	## While parsing, tables remember how they were defined, which decides
	## what may still be added to them.
	##
	## - `Implicit`: created as the parent of a header, such as `a` for `[a.b]`;
	##   a later `[a]` may still define it.
	## - `Header`: defined by `[a]`, or the root.
	## - `Dotted`: defined by a dotted key such as `a.b = 1`.
	## - `Inline`: written as `{ ... }`; nothing may be added afterwards.
	Kind : [Implicit, Header, Dotted, Inline]

	Node := [
		Leaf(TomlValue),
		Branch({ entries : List((Str, TomlParse.Node)), kind : TomlParse.Kind }),
		## The tables of `[[name]]`, in order. Headers and keys go to the last.
		Tables(List(TomlParse.Node)),
	]

	parse : Str -> Try(TomlValue, [TomlSyntax(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		var $pos = 0
		var $root = TomlParse.Node.Branch({ entries: [], kind: Header })
		var $current = []
		while $pos < bytes.len() {
			$pos = skip_blank(bytes, $pos)
			byte = bytes.get($pos) ?? 0
			if $pos >= bytes.len() {
				break
			} else if byte == '#' or byte == '\n' or byte == '\r' {
				$pos = end_line(bytes, $pos)?
			} else if byte == '[' {
				is_array = bytes.get($pos + 1) == Ok('[')
				keys_start = skip_blank(bytes, $pos + (if is_array { 2 } else { 1 }))
				parsed = parse_key(bytes, keys_start)?
				after = skip_blank(bytes, parsed.pos)
				closing = if is_array { "]]".to_utf8() } else { "]".to_utf8() }
				if bytes.sublist({ start: after, len: closing.len() }) != closing {
					return Err(syntax(bytes, after, "expected ${Str.from_utf8(closing) ?? "]"} to close the table header"))
				}
				$root = match define_table($root, parsed.keys, if is_array { ArrayHeader } else { Header }) {
					Ok(node) => node
					Err(message) => return Err(syntax(bytes, $pos, message))
				}
				$current = parsed.keys
				$pos = end_line(bytes, after + closing.len())?
			} else {
				parsed = parse_key(bytes, $pos)?
				equals = skip_blank(bytes, parsed.pos)
				if bytes.get(equals) != Ok('=') {
					return Err(syntax(bytes, equals, "expected = after the key"))
				}
				value = parse_value(bytes, skip_blank(bytes, equals + 1))?
				$root = match set_key($root, $current, parsed.keys, value.node) {
					Ok(node) => node
					Err(message) => return Err(syntax(bytes, $pos, message))
				}
				$pos = end_line(bytes, value.pos)?
			}
		}
		Ok(to_value($root))
	}

	## A date-time written alone, such as `1979-05-27T07:32:00Z`.
	date_time : Str -> Try(TomlValue, [NotDateTime])
	date_time = |text|
		match parse_date_time(text.to_utf8()) {
			Ok(value) => Ok(value)
			Err(_) => Err(NotDateTime)
		}
}

## ---- document structure -------------------------------------------------

to_value : TomlParse.Node -> TomlValue
to_value = |node|
	match node {
		Leaf(value) => value
		Branch({ entries, .. }) => Table(entries.map(|(key, child)| (key, to_value(child))))
		Tables(items) => Array(items.map(to_value))
	}

entry_index : List((Str, TomlParse.Node)), Str -> Try(U64, [NotFound])
entry_index = |entries, key| entries.find_first_index(|(name, _)| name == key)

replace_entry : List((Str, TomlParse.Node)), U64, TomlParse.Node -> List((Str, TomlParse.Node))
replace_entry = |entries, index, node|
	match entries.get(index) {
		Ok((key, _)) => entries.set(index, (key, node)) ?? entries
		Err(_) => entries
	}

dotted : List(Str) -> Str
dotted = |keys| Str.join_with(keys, ".")

## Defines `[keys]` or `[[keys]]`, creating implicit parent tables.
define_table : TomlParse.Node, List(Str), [Header, ArrayHeader] -> Try(TomlParse.Node, Str)
define_table = |root, keys, mode| define_in(root, keys, keys, mode)

define_in : TomlParse.Node, List(Str), List(Str), [Header, ArrayHeader] -> Try(TomlParse.Node, Str)
define_in = |node, keys, full, mode|
	match node {
		Branch({ entries, kind }) => {
			key = keys.first() ?? ""
			rest = keys.drop_first(1)
			fresh = TomlParse.Node.Branch({ entries: [], kind: Header })
			match entry_index(entries, key) {
				Err(_) =>
					if rest.is_empty() {
						created = if mode == ArrayHeader { TomlParse.Node.Tables([fresh]) } else { fresh }
						Ok(Branch({ entries: entries.append((key, created)), kind }))
					} else {
						child = define_in(TomlParse.Node.Branch({ entries: [], kind: Implicit }), rest, full, mode)?
						Ok(Branch({ entries: entries.append((key, child)), kind }))
					}
				Ok(index) => {
					(_, existing) = entries.get(index) ?? (key, fresh)
					updated = if rest.is_empty() {
						define_last(existing, full, mode)?
					} else {
						define_through(existing, rest, full, mode)?
					}
					Ok(Branch({ entries: replace_entry(entries, index, updated), kind }))
				}
			}
		}
		_ => Err("[${dotted(full)}] goes through a key that is not a table")
	}

define_through : TomlParse.Node, List(Str), List(Str), [Header, ArrayHeader] -> Try(TomlParse.Node, Str)
define_through = |node, rest, full, mode|
	match node {
		Branch({ kind: Inline, .. }) => Err("[${dotted(full)}] adds to an inline table")
		Branch(_) => define_in(node, rest, full, mode)
		Tables(items) => {
			last = items.last() ?? TomlParse.Node.Branch({ entries: [], kind: Header })
			updated = define_in(last, rest, full, mode)?
			Ok(Tables(items.set(items.len() - 1, updated) ?? items))
		}
		Leaf(_) => Err("[${dotted(full)}] goes through a key that already has a value")
	}

define_last : TomlParse.Node, List(Str), [Header, ArrayHeader] -> Try(TomlParse.Node, Str)
define_last = |node, full, mode|
	match (node, mode) {
		(Branch({ entries, kind: Implicit }), Header) => Ok(Branch({ entries, kind: Header }))
		(Branch({ kind: Header, .. }), Header) => Err("table [${dotted(full)}] is defined twice")
		(Branch(_), _) => Err("[${dotted(full)}] is already defined")
		(Tables(items), ArrayHeader) => Ok(Tables(items.append(TomlParse.Node.Branch({ entries: [], kind: Header }))))
		(Tables(_), Header) => Err("[${dotted(full)}] is already an array of tables")
		(Leaf(_), _) => Err("[${dotted(full)}] already has a value")
	}

## Sets `keys = value` in the table at `current`.
set_key : TomlParse.Node, List(Str), List(Str), TomlParse.Node -> Try(TomlParse.Node, Str)
set_key = |root, current, keys, value| at_table(root, current, |table| insert_dotted(table, keys, keys, value))

## Applies `update` to the table at `path`, entering the last table of an
## array of tables.
at_table : TomlParse.Node, List(Str), (TomlParse.Node -> Try(TomlParse.Node, Str)) -> Try(TomlParse.Node, Str)
at_table = |node, path, update|
	match path.first() {
		Err(_) =>
			match node {
				Tables(items) => {
					last = items.last() ?? TomlParse.Node.Branch({ entries: [], kind: Header })
					updated = update(last)?
					Ok(Tables(items.set(items.len() - 1, updated) ?? items))
				}
				_ => update(node)
			}
		Ok(key) =>
			match node {
				Branch({ entries, kind }) =>
					match entry_index(entries, key) {
						Ok(index) => {
							(_, child) = entries.get(index) ?? (key, node)
							updated = at_table(child, path.drop_first(1), update)?
							Ok(Branch({ entries: replace_entry(entries, index, updated), kind }))
						}
						Err(_) => Err("the current table is missing")
					}
				Tables(items) => {
					last = items.last() ?? TomlParse.Node.Branch({ entries: [], kind: Header })
					updated = at_table(last, path, update)?
					Ok(Tables(items.set(items.len() - 1, updated) ?? items))
				}
				Leaf(_) => Err("the current table is missing")
			}
	}

insert_dotted : TomlParse.Node, List(Str), List(Str), TomlParse.Node -> Try(TomlParse.Node, Str)
insert_dotted = |table, keys, full, value|
	match table {
		Branch({ entries, kind }) => {
			key = keys.first() ?? ""
			rest = keys.drop_first(1)
			match entry_index(entries, key) {
				Err(_) =>
					if rest.is_empty() {
						Ok(Branch({ entries: entries.append((key, value)), kind }))
					} else {
						child = insert_dotted(TomlParse.Node.Branch({ entries: [], kind: Dotted }), rest, full, value)?
						Ok(Branch({ entries: entries.append((key, child)), kind }))
					}
				Ok(index) =>
					if rest.is_empty() {
						Err("key ${dotted(full)} is defined twice")
					} else {
						(_, existing) = entries.get(index) ?? (key, value)
						updated = match existing {
							Branch({ entries: inner, kind: Dotted }) => insert_dotted(Branch({ entries: inner, kind: Dotted }), rest, full, value)?
							Branch({ entries: inner, kind: Implicit }) => insert_dotted(Branch({ entries: inner, kind: Dotted }), rest, full, value)?
							Branch({ kind: Inline, .. }) => return Err("key ${dotted(full)} adds to an inline table")
							Branch(_) => return Err("key ${dotted(full)} adds to a table defined by a header")
							Tables(_) => return Err("key ${dotted(full)} adds to an array of tables")
							Leaf(_) => return Err("key ${dotted(full)} goes through a key that already has a value")
						}
						Ok(Branch({ entries: replace_entry(entries, index, updated), kind }))
					}
			}
		}
		_ => Err("key ${dotted(full)} is not in a table")
	}

## ---- lexical helpers ----------------------------------------------------

line_of : List(U8), U64 -> U64
line_of = |bytes, pos| {
	var $line = 1
	var $index = 0
	while $index < pos and $index < bytes.len() {
		if bytes.get($index) == Ok('\n') {
			$line = $line + 1
		}
		$index = $index + 1
	}
	$line
}

syntax : List(U8), U64, Str -> [TomlSyntax(Str)]
syntax = |bytes, pos, message| TomlSyntax("line ${line_of(bytes, pos).to_str()}: ${message}")

## Skips spaces and tabs.
skip_blank : List(U8), U64 -> U64
skip_blank = |bytes, start| {
	var $pos = start
	while bytes.get($pos) == Ok(' ') or bytes.get($pos) == Ok('\t') {
		$pos = $pos + 1
	}
	$pos
}

## After a statement: blanks, an optional comment, then a newline or the end.
end_line : List(U8), U64 -> Try(U64, [TomlSyntax(Str)])
end_line = |bytes, start| {
	var $pos = skip_blank(bytes, start)
	if bytes.get($pos) == Ok('#') {
		while $pos < bytes.len() and bytes.get($pos) != Ok('\n') {
			byte = bytes.get($pos) ?? 0
			if byte == '\r' and bytes.get($pos + 1) == Ok('\n') {
				break
			}
			if is_control(byte) and byte != '\t' {
				return Err(syntax(bytes, $pos, "control character in a comment"))
			}
			$pos = $pos + 1
		}
	}
	if $pos >= bytes.len() {
		Ok($pos)
	} else if bytes.get($pos) == Ok('\n') {
		Ok($pos + 1)
	} else if bytes.get($pos) == Ok('\r') and bytes.get($pos + 1) == Ok('\n') {
		Ok($pos + 2)
	} else {
		Err(syntax(bytes, $pos, "expected the end of the line"))
	}
}

## Skips blanks, newlines, and comments, as allowed inside arrays.
skip_array_space : List(U8), U64 -> Try(U64, [TomlSyntax(Str)])
skip_array_space = |bytes, start| {
	var $pos = start
	while Bool.True {
		$pos = skip_blank(bytes, $pos)
		byte = bytes.get($pos) ?? 0
		if byte == '#' or byte == '\n' or byte == '\r' {
			$pos = end_line(bytes, $pos)?
		} else {
			break
		}
	}
	Ok($pos)
}

is_control : U8 -> Bool
is_control = |byte| byte < 0x20 or byte == 0x7F

is_bare_key_byte : U8 -> Bool
is_bare_key_byte = |byte| (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-'

is_digit : U8 -> Bool
is_digit = |byte| byte >= '0' and byte <= '9'

## ---- keys -------------------------------------------------------------

## A dotted key: simple keys separated by dots, with blanks around the dots.
parse_key : List(U8), U64 -> Try({ keys : List(Str), pos : U64 }, [TomlSyntax(Str)])
parse_key = |bytes, start| {
	var $keys = []
	var $pos = start
	while Bool.True {
		simple = parse_simple_key(bytes, skip_blank(bytes, $pos))?
		$keys = $keys.append(simple.key)
		after = skip_blank(bytes, simple.pos)
		if bytes.get(after) == Ok('.') {
			$pos = after + 1
		} else {
			$pos = simple.pos
			break
		}
	}
	Ok({ keys: $keys, pos: $pos })
}

parse_simple_key : List(U8), U64 -> Try({ key : Str, pos : U64 }, [TomlSyntax(Str)])
parse_simple_key = |bytes, start| {
	byte = bytes.get(start) ?? 0
	if byte == '"' {
		parsed = parse_basic_string(bytes, start)?
		Ok({ key: parsed.text, pos: parsed.pos })
	} else if byte == '\'' {
		parsed = parse_literal_string(bytes, start)?
		Ok({ key: parsed.text, pos: parsed.pos })
	} else {
		var $pos = start
		while is_bare_key_byte(bytes.get($pos) ?? 0) {
			$pos = $pos + 1
		}
		if $pos == start {
			Err(syntax(bytes, start, "expected a key"))
		} else {
			Ok({ key: Str.from_utf8(bytes.sublist({ start, len: $pos - start })) ?? "", pos: $pos })
		}
	}
}

## ---- strings ----------------------------------------------------------

utf8_of : List(U8), U64, List(U8) -> Try(Str, [TomlSyntax(Str)])
utf8_of = |bytes, pos, raw|
	match Str.from_utf8(raw) {
		Ok(text) => Ok(text)
		Err(_) => Err(syntax(bytes, pos, "invalid UTF-8"))
	}

hex_digit : U8 -> Try(U32, [NotHex])
hex_digit = |byte|
	if byte >= '0' and byte <= '9' {
		Ok((byte - '0').to_u32())
	} else if byte >= 'a' and byte <= 'f' {
		Ok((byte - 'a').to_u32() + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok((byte - 'A').to_u32() + 10)
	} else {
		Err(NotHex)
	}

## The UTF-8 bytes of a Unicode scalar value.
encode_scalar : U32 -> Try(List(U8), [NotScalar])
encode_scalar = |code|
	if code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) {
		Err(NotScalar)
	} else if code < 0x80 {
		Ok([code.to_u8_wrap()])
	} else if code < 0x800 {
		Ok([(0xC0.U32.bitwise_or(code.shr_zf_wrap(6))).to_u8_wrap(), (0x80.U32.bitwise_or(code.bitwise_and(0x3F))).to_u8_wrap()])
	} else if code < 0x10000 {
		Ok([
			(0xE0.U32.bitwise_or(code.shr_zf_wrap(12))).to_u8_wrap(),
			(0x80.U32.bitwise_or(code.shr_zf_wrap(6).bitwise_and(0x3F))).to_u8_wrap(),
			(0x80.U32.bitwise_or(code.bitwise_and(0x3F))).to_u8_wrap(),
		])
	} else {
		Ok([
			(0xF0.U32.bitwise_or(code.shr_zf_wrap(18))).to_u8_wrap(),
			(0x80.U32.bitwise_or(code.shr_zf_wrap(12).bitwise_and(0x3F))).to_u8_wrap(),
			(0x80.U32.bitwise_or(code.shr_zf_wrap(6).bitwise_and(0x3F))).to_u8_wrap(),
			(0x80.U32.bitwise_or(code.bitwise_and(0x3F))).to_u8_wrap(),
		])
	}

## An escape after a backslash in a basic string; `pos` is at the backslash.
parse_escape : List(U8), U64 -> Try({ out : List(U8), pos : U64 }, [TomlSyntax(Str)])
parse_escape = |bytes, pos| {
	byte = bytes.get(pos + 1) ?? 0
	simple = |out| Ok({ out, pos: pos + 2 })
	if byte == 'b' {
		simple([0x08])
	} else if byte == 't' {
		simple(['\t'])
	} else if byte == 'n' {
		simple(['\n'])
	} else if byte == 'f' {
		simple([0x0C])
	} else if byte == 'r' {
		simple(['\r'])
	} else if byte == '"' {
		simple(['"'])
	} else if byte == '\\' {
		simple(['\\'])
	} else if byte == 'u' or byte == 'U' {
		count = if byte == 'u' { 4 } else { 8 }
		var $code = 0
		var $index = 0
		while $index < count {
			digit = match hex_digit(bytes.get(pos + 2 + $index) ?? 0) {
				Ok(value) => value
				Err(_) => return Err(syntax(bytes, pos, "bad \\u escape"))
			}
			$code = $code * 16 + digit
			$index = $index + 1
		}
		match encode_scalar($code) {
			Ok(out) => Ok({ out, pos: pos + 2 + count })
			Err(_) => Err(syntax(bytes, pos, "escape is not a Unicode scalar value"))
		}
	} else {
		Err(syntax(bytes, pos, "unknown escape"))
	}
}

parse_basic_string : List(U8), U64 -> Try({ text : Str, pos : U64 }, [TomlSyntax(Str)])
parse_basic_string = |bytes, start| {
	var $out = []
	var $pos = start + 1
	while Bool.True {
		byte = match bytes.get($pos) {
			Ok(value) => value
			Err(_) => return Err(syntax(bytes, start, "unterminated string"))
		}
		if byte == '"' {
			break
		} else if byte == '\\' {
			escaped = parse_escape(bytes, $pos)?
			$out = $out.concat(escaped.out)
			$pos = escaped.pos
		} else if byte == '\n' or (is_control(byte) and byte != '\t') {
			return Err(syntax(bytes, $pos, "control character or newline in a string"))
		} else {
			$out = $out.append(byte)
			$pos = $pos + 1
		}
	}
	text = utf8_of(bytes, start, $out)?
	Ok({ text, pos: $pos + 1 })
}

parse_literal_string : List(U8), U64 -> Try({ text : Str, pos : U64 }, [TomlSyntax(Str)])
parse_literal_string = |bytes, start| {
	var $pos = start + 1
	while bytes.get($pos) != Ok('\'') {
		byte = match bytes.get($pos) {
			Ok(value) => value
			Err(_) => return Err(syntax(bytes, start, "unterminated string"))
		}
		if byte == '\n' or (is_control(byte) and byte != '\t') {
			return Err(syntax(bytes, $pos, "control character or newline in a string"))
		}
		$pos = $pos + 1
	}
	text = utf8_of(bytes, start, bytes.sublist({ start: start + 1, len: $pos - start - 1 }))?
	Ok({ text, pos: $pos + 1 })
}

## A newline right after the opening delimiter is dropped.
skip_first_newline : List(U8), U64 -> U64
skip_first_newline = |bytes, pos|
	if bytes.get(pos) == Ok('\n') {
		pos + 1
	} else if bytes.get(pos) == Ok('\r') and bytes.get(pos + 1) == Ok('\n') {
		pos + 2
	} else {
		pos
	}

## The closing delimiter of a multi-line string may be followed by up to two
## more quotes, which belong to the content.
closing_quotes : List(U8), U64, U8 -> U64
closing_quotes = |bytes, pos, quote| {
	var $count = 0
	while bytes.get(pos + $count) == Ok(quote) {
		$count = $count + 1
	}
	$count
}

parse_multiline_basic : List(U8), U64 -> Try({ text : Str, pos : U64 }, [TomlSyntax(Str)])
parse_multiline_basic = |bytes, start| {
	var $out = []
	var $pos = skip_first_newline(bytes, start + 3)
	while Bool.True {
		byte = match bytes.get($pos) {
			Ok(value) => value
			Err(_) => return Err(syntax(bytes, start, "unterminated multi-line string"))
		}
		if byte == '"' and closing_quotes(bytes, $pos, '"') >= 3 {
			quotes = closing_quotes(bytes, $pos, '"')
			if quotes > 5 {
				return Err(syntax(bytes, $pos, "too many quotes at the end of a multi-line string"))
			}
			$out = $out.concat(List.repeat('"', quotes - 3))
			$pos = $pos + quotes
			break
		} else if byte == '\\' {
			# A backslash at the end of a line trims the newline and the
			# whitespace that follows.
			after = skip_blank(bytes, $pos + 1)
			next = bytes.get(after) ?? 0
			if next == '\n' or (next == '\r' and bytes.get(after + 1) == Ok('\n')) {
				var $skip = after
				while Bool.True {
					current = bytes.get($skip) ?? 0
					if current == ' ' or current == '\t' or current == '\n' {
						$skip = $skip + 1
					} else if current == '\r' and bytes.get($skip + 1) == Ok('\n') {
						$skip = $skip + 2
					} else {
						break
					}
				}
				$pos = $skip
			} else {
				escaped = parse_escape(bytes, $pos)?
				$out = $out.concat(escaped.out)
				$pos = escaped.pos
			}
		} else if byte == '\r' and bytes.get($pos + 1) == Ok('\n') {
			$out = $out.concat(['\r', '\n'])
			$pos = $pos + 2
		} else if byte != '\n' and is_control(byte) and byte != '\t' {
			return Err(syntax(bytes, $pos, "control character in a string"))
		} else {
			$out = $out.append(byte)
			$pos = $pos + 1
		}
	}
	text = utf8_of(bytes, start, $out)?
	Ok({ text, pos: $pos })
}

parse_multiline_literal : List(U8), U64 -> Try({ text : Str, pos : U64 }, [TomlSyntax(Str)])
parse_multiline_literal = |bytes, start| {
	var $out = []
	var $pos = skip_first_newline(bytes, start + 3)
	while Bool.True {
		byte = match bytes.get($pos) {
			Ok(value) => value
			Err(_) => return Err(syntax(bytes, start, "unterminated multi-line string"))
		}
		if byte == '\'' and closing_quotes(bytes, $pos, '\'') >= 3 {
			quotes = closing_quotes(bytes, $pos, '\'')
			if quotes > 5 {
				return Err(syntax(bytes, $pos, "too many quotes at the end of a multi-line string"))
			}
			$out = $out.concat(List.repeat('\'', quotes - 3))
			$pos = $pos + quotes
			break
		} else if byte == '\r' and bytes.get($pos + 1) == Ok('\n') {
			$out = $out.concat(['\r', '\n'])
			$pos = $pos + 2
		} else if byte != '\n' and is_control(byte) and byte != '\t' {
			return Err(syntax(bytes, $pos, "control character in a string"))
		} else {
			$out = $out.append(byte)
			$pos = $pos + 1
		}
	}
	text = utf8_of(bytes, start, $out)?
	Ok({ text, pos: $pos })
}

## ---- values -----------------------------------------------------------

parse_value : List(U8), U64 -> Try({ node : TomlParse.Node, pos : U64 }, [TomlSyntax(Str)])
parse_value = |bytes, start| {
	leaf = |value, pos| Ok({ node: TomlParse.Node.Leaf(value), pos })
	byte = bytes.get(start) ?? 0
	if byte == '"' {
		parsed = if bytes.sublist({ start, len: 3 }) == ['"', '"', '"'] { parse_multiline_basic(bytes, start)? } else { parse_basic_string(bytes, start)? }
		leaf(String(parsed.text), parsed.pos)
	} else if byte == '\'' {
		parsed = if bytes.sublist({ start, len: 3 }) == ['\'', '\'', '\''] { parse_multiline_literal(bytes, start)? } else { parse_literal_string(bytes, start)? }
		leaf(String(parsed.text), parsed.pos)
	} else if byte == '[' {
		parse_array(bytes, start)
	} else if byte == '{' {
		parse_inline_table(bytes, start)
	} else if bytes.sublist({ start, len: 4 }) == "true".to_utf8() and !is_bare_key_byte(bytes.get(start + 4) ?? 0) {
		leaf(Boolean(Bool.True), start + 4)
	} else if bytes.sublist({ start, len: 5 }) == "false".to_utf8() and !is_bare_key_byte(bytes.get(start + 5) ?? 0) {
		leaf(Boolean(Bool.False), start + 5)
	} else {
		parse_scalar(bytes, start)
	}
}

parse_array : List(U8), U64 -> Try({ node : TomlParse.Node, pos : U64 }, [TomlSyntax(Str)])
parse_array = |bytes, start| {
	var $items = []
	var $pos = skip_array_space(bytes, start + 1)?
	while bytes.get($pos) != Ok(']') {
		if $pos >= bytes.len() {
			return Err(syntax(bytes, start, "unterminated array"))
		}
		item = parse_value(bytes, $pos)?
		$items = $items.append(to_value(item.node))
		$pos = skip_array_space(bytes, item.pos)?
		if bytes.get($pos) == Ok(',') {
			$pos = skip_array_space(bytes, $pos + 1)?
		} else if bytes.get($pos) != Ok(']') {
			return Err(syntax(bytes, $pos, "expected , or ] in an array"))
		}
	}
	Ok({ node: TomlParse.Node.Leaf(Array($items)), pos: $pos + 1 })
}

parse_inline_table : List(U8), U64 -> Try({ node : TomlParse.Node, pos : U64 }, [TomlSyntax(Str)])
parse_inline_table = |bytes, start| {
	var $table = TomlParse.Node.Branch({ entries: [], kind: Header })
	var $pos = skip_blank(bytes, start + 1)
	if bytes.get($pos) == Ok('}') {
		return Ok({ node: TomlParse.Node.Branch({ entries: [], kind: Inline }), pos: $pos + 1 })
	}
	while Bool.True {
		parsed = parse_key(bytes, $pos)?
		equals = skip_blank(bytes, parsed.pos)
		if bytes.get(equals) != Ok('=') {
			return Err(syntax(bytes, equals, "expected = after the key"))
		}
		value = parse_value(bytes, skip_blank(bytes, equals + 1))?
		$table = match insert_dotted($table, parsed.keys, parsed.keys, value.node) {
			Ok(node) => node
			Err(message) => return Err(syntax(bytes, $pos, message))
		}
		$pos = skip_blank(bytes, value.pos)
		if bytes.get($pos) == Ok(',') {
			$pos = skip_blank(bytes, $pos + 1)
		} else if bytes.get($pos) == Ok('}') {
			break
		} else {
			return Err(syntax(bytes, $pos, "expected , or } in an inline table"))
		}
	}
	entries = match $table {
		Branch(inner) => inner.entries
		_ => []
	}
	Ok({ node: TomlParse.Node.Branch({ entries, kind: Inline }), pos: $pos + 1 })
}

## A number or a date-time: the run of bytes up to a delimiter, plus the time
## part when a date is followed by a space and a time.
parse_scalar : List(U8), U64 -> Try({ node : TomlParse.Node, pos : U64 }, [TomlSyntax(Str)])
parse_scalar = |bytes, start| {
	var $end = start
	while Bool.True {
		byte = bytes.get($end) ?? 0
		if is_bare_key_byte(byte) or byte == '+' or byte == '.' or byte == ':' {
			$end = $end + 1
		} else {
			break
		}
	}
	# `1979-05-27 07:32:00`: a space between the date and the time.
	if $end - start == 10 and bytes.get(start + 4) == Ok('-') and bytes.get($end) == Ok(' ') and is_digit(bytes.get($end + 1) ?? 0) and is_digit(bytes.get($end + 2) ?? 0) and bytes.get($end + 3) == Ok(':') {
		$end = $end + 1
		while Bool.True {
			byte = bytes.get($end) ?? 0
			if is_bare_key_byte(byte) or byte == '+' or byte == '.' or byte == ':' {
				$end = $end + 1
			} else {
				break
			}
		}
	}
	token = bytes.sublist({ start, len: $end - start })
	if token.is_empty() {
		return Err(syntax(bytes, start, "expected a value"))
	}
	value = if token.get(4) == Ok('-') or token.get(2) == Ok(':') {
		parse_date_time(token)
	} else {
		parse_number(token)
	}
	match value {
		Ok(parsed) => Ok({ node: TomlParse.Node.Leaf(parsed), pos: $end })
		Err(message) => Err(syntax(bytes, start, message))
	}
}

## ---- numbers ----------------------------------------------------------

## Digits with single underscores between them; the underscores removed.
plain_digits : List(U8), (U8 -> Bool) -> Try(List(U8), [Bad])
plain_digits = |raw, is_valid| {
	if raw.is_empty() or raw.first() == Ok('_') or raw.last() == Ok('_') {
		return Err(Bad)
	}
	var $out = []
	var $previous = 0
	for byte in raw {
		if byte == '_' {
			if $previous == '_' {
				return Err(Bad)
			}
		} else if is_valid(byte) {
			$out = $out.append(byte)
		} else {
			return Err(Bad)
		}
		$previous = byte
	}
	Ok($out)
}

parse_number : List(U8) -> Try(TomlValue, Str)
parse_number = |token| {
	sign = token.first() ?? 0
	unsigned = if sign == '+' or sign == '-' { token.drop_first(1) } else { token }
	negative = sign == '-'
	if unsigned == "inf".to_utf8() {
		return Ok(Float(if negative { -F64.infinity } else { F64.infinity }))
	}
	if unsigned == "nan".to_utf8() {
		return Ok(Float(F64.nan))
	}
	prefix = unsigned.take_first(2)
	if prefix == "0x".to_utf8() or prefix == "0o".to_utf8() or prefix == "0b".to_utf8() {
		if sign == '+' or sign == '-' {
			return Err("a sign is not allowed in ")
		}
		return parse_radix(unsigned.drop_first(2), prefix)
	}
	is_float = unsigned.any(|byte| byte == '.' or byte == 'e' or byte == 'E')
	if is_float {
		parse_float(token, unsigned)
	} else {
		digits = match plain_digits(unsigned, is_digit) {
			Ok(value) => value
			Err(_) => return Err("invalid number")
		}
		if digits.len() > 1 and digits.first() == Ok('0') {
			return Err("leading zero in a number")
		}
		match I64.from_str(Str.from_utf8(if negative { ['-'].concat(digits) } else { digits }) ?? "") {
			Ok(value) => Ok(Integer(value))
			Err(_) => Err("integer out of range for I64")
		}
	}
}

parse_radix : List(U8), List(U8) -> Try(TomlValue, Str)
parse_radix = |raw, prefix| {
	base = if prefix == "0x".to_utf8() { 16 } else if prefix == "0o".to_utf8() { 8 } else { 2 }
	valid = |byte|
		match hex_digit(byte) {
			Ok(value) => value < base
			Err(_) => Bool.False
		}
	digits = match plain_digits(raw, valid) {
		Ok(value) => value
		Err(_) => return Err("invalid number")
	}
	var $value = 0.I128
	for byte in digits {
		digit = (hex_digit(byte) ?? 0).to_i128()
		$value = $value * base.to_i128() + digit
		if $value > 9_223_372_036_854_775_807 {
			return Err("integer out of range for I64")
		}
	}
	Ok(Integer($value.to_i64_wrap()))
}

parse_float : List(U8), List(U8) -> Try(TomlValue, Str)
parse_float = |token, unsigned| {
	bad = Err("invalid float")
	# Split at the exponent, then at the decimal point.
	exponent_at = unsigned.find_first_index(|byte| byte == 'e' or byte == 'E')
	(mantissa, exponent) = match exponent_at {
		Ok(index) => (unsigned.take_first(index), Ok(unsigned.drop_first(index + 1)))
		Err(_) => (unsigned, Err(NoExponent))
	}
	(integer_part, fraction_part) = match mantissa.find_first_index(|byte| byte == '.') {
		Ok(index) => (mantissa.take_first(index), Ok(mantissa.drop_first(index + 1)))
		Err(_) => (mantissa, Err(NoFraction))
	}
	integer_digits = match plain_digits(integer_part, is_digit) {
		Ok(value) => value
		Err(_) => return bad
	}
	if integer_digits.len() > 1 and integer_digits.first() == Ok('0') {
		return Err("leading zero in a number")
	}
	fraction_digits = match fraction_part {
		Ok(raw) =>
			match plain_digits(raw, is_digit) {
				Ok(value) => Ok(value)
				Err(_) => return bad
			}
		Err(_) => Err(NoFraction)
	}
	exponent_digits = match exponent {
		Ok(raw) => {
			exponent_sign = raw.first() ?? 0
			body = if exponent_sign == '+' or exponent_sign == '-' { raw.drop_first(1) } else { raw }
			match plain_digits(body, is_digit) {
				Ok(value) => Ok(if exponent_sign == '-' { ['-'].concat(value) } else { value })
				Err(_) => return bad
			}
		}
		Err(_) => Err(NoExponent)
	}
	sign = token.first() ?? 0
	normalized = (if sign == '-' { ['-'] } else { [] })
		.concat(integer_digits)
		.concat(match fraction_digits { Ok(value) => ['.'].concat(value), Err(_) => [] })
		.concat(match exponent_digits { Ok(value) => ['e'].concat(value), Err(_) => [] })
	match F64.from_str(Str.from_utf8(normalized) ?? "") {
		Ok(value) => Ok(Float(value))
		Err(_) => bad
	}
}

## ---- date-times -------------------------------------------------------

## Exactly `count` digits at `start` as a number.
digits_at : List(U8), U64, U64 -> Try(U32, [Bad])
digits_at = |token, start, count| {
	var $value = 0
	var $index = 0
	while $index < count {
		byte = token.get(start + $index) ?? 0
		if !is_digit(byte) {
			return Err(Bad)
		}
		$value = $value * 10 + (byte - '0').to_u32()
		$index = $index + 1
	}
	Ok($value)
}

is_leap : U32 -> Bool
is_leap = |year| (year % 4 == 0 and year % 100 != 0) or year % 400 == 0

days_in : U32, U32 -> U32
days_in = |year, month|
	if month == 2 {
		if is_leap(year) { 29 } else { 28 }
	} else if month == 4 or month == 6 or month == 9 or month == 11 {
		30
	} else {
		31
	}

parse_date : List(U8) -> Try(TomlValue.Date, [Bad])
parse_date = |token| {
	if token.len() != 10 or token.get(4) != Ok('-') or token.get(7) != Ok('-') {
		return Err(Bad)
	}
	year = digits_at(token, 0, 4)?
	month = digits_at(token, 5, 2)?
	day = digits_at(token, 8, 2)?
	if month < 1 or month > 12 or day < 1 or day > days_in(year, month) {
		return Err(Bad)
	}
	Ok({ year: year.to_u16_wrap(), month: month.to_u8_wrap(), day: day.to_u8_wrap() })
}

## `HH:MM:SS` with an optional fraction; returns the time and where it ended.
parse_time : List(U8) -> Try({ time : TomlValue.Time, rest : List(U8) }, [Bad])
parse_time = |token| {
	if token.len() < 8 or token.get(2) != Ok(':') or token.get(5) != Ok(':') {
		return Err(Bad)
	}
	hour = digits_at(token, 0, 2)?
	minute = digits_at(token, 3, 2)?
	second = digits_at(token, 6, 2)?
	# RFC 3339 allows a leap second, 60.
	if hour > 23 or minute > 59 or second > 60 {
		return Err(Bad)
	}
	var $pos = 8
	var $nanosecond = 0
	if token.get(8) == Ok('.') {
		$pos = 9
		var $scale = 100_000_000
		while is_digit(token.get($pos) ?? 0) {
			# Digits past nanoseconds are truncated.
			$nanosecond = $nanosecond + ((token.get($pos) ?? '0') - '0').to_u32() * $scale
			$scale = $scale / 10
			$pos = $pos + 1
		}
		if $pos == 9 {
			return Err(Bad)
		}
	}
	Ok({ time: { hour: hour.to_u8_wrap(), minute: minute.to_u8_wrap(), second: second.to_u8_wrap(), nanosecond: $nanosecond }, rest: token.drop_first($pos) })
}

parse_date_time : List(U8) -> Try(TomlValue, Str)
parse_date_time = |token| {
	text = Str.from_utf8(token) ?? ""
	bad = Err("invalid date-time")
	if token.get(2) == Ok(':') {
		return match parse_time(token) {
			Ok({ time, rest }) if rest.is_empty() => Ok(LocalTime({ time, text }))
			_ => bad
		}
	}
	date = match parse_date(token.take_first(10)) {
		Ok(value) => value
		Err(_) => return bad
	}
	if token.len() == 10 {
		return Ok(LocalDate({ date, text }))
	}
	separator = token.get(10) ?? 0
	if separator != 'T' and separator != 't' and separator != ' ' {
		return bad
	}
	(time, rest) = match parse_time(token.drop_first(11)) {
		Ok(parsed) => (parsed.time, parsed.rest)
		Err(_) => return bad
	}
	if rest.is_empty() {
		Ok(LocalDateTime({ date, time, text }))
	} else if rest == ['Z'] or rest == ['z'] {
		Ok(OffsetDateTime({ date, time, offset_minutes: 0, text }))
	} else {
		offset_sign = rest.first() ?? 0
		if (offset_sign != '+' and offset_sign != '-') or rest.len() != 6 or rest.get(3) != Ok(':') {
			return bad
		}
		hours = match digits_at(rest, 1, 2) { Ok(value) => value, Err(_) => return bad }
		minutes = match digits_at(rest, 4, 2) { Ok(value) => value, Err(_) => return bad }
		if hours > 23 or minutes > 59 {
			return bad
		}
		total = (hours * 60 + minutes).to_i16_wrap()
		Ok(OffsetDateTime({ date, time, offset_minutes: if offset_sign == '-' { -total } else { total }, text }))
	}
}

## ---- tests ------------------------------------------------------------

is_syntax_error : Str -> Bool
is_syntax_error = |text|
	match TomlParse.parse(text) {
		Err(TomlSyntax(_)) => Bool.True
		Ok(_) => Bool.False
	}

expect TomlParse.parse("") == Ok(Table([]))

expect {
	text =
		\\# comment
		\\title = "TOML" # trailing
		\\
		\\[owner]
		\\name = "Tom"
		\\
		\\[database]
		\\ports = [ 8000, 8001, 8002 ]
		\\enabled = true
		\\temp_targets = { cpu = 79.5, case = 72.0 }
	expected : TomlValue
	expected = Table([
		("title", String("TOML")),
		("owner", Table([("name", String("Tom"))])),
		("database", Table([
			("ports", Array([Integer(8000), Integer(8001), Integer(8002)])),
			("enabled", Boolean(Bool.True)),
			("temp_targets", Table([("cpu", Float(79.5)), ("case", Float(72.0))])),
		])),
	])
	TomlParse.parse(text) == Ok(expected)
}

# Keys: bare, quoted, dotted with blanks around the dots.
expect {
	text =
		\\"quoted key" = 1
		\\'literal' = 2
		\\site . "google.com" = true
		\\fruit.apple.color = "red"
		\\fruit.apple.taste.sweet = true
	expected : TomlValue
	expected = Table([
		("quoted key", Integer(1)),
		("literal", Integer(2)),
		("site", Table([("google.com", Boolean(Bool.True))])),
		("fruit", Table([("apple", Table([("color", String("red")), ("taste", Table([("sweet", Boolean(Bool.True))]))]))])),
	])
	TomlParse.parse(text) == Ok(expected)
}

# Strings: escapes, \u, multi-line with line-ending backslash, literal forms.
expect {
	text =
		\\a = "tab\\there \\"q\\" \\u00E9 \\U0001F600"
		\\b = """
		\\Roses
		\\Violets"""
		\\c = """\\
		\\    The quick \\
		\\    brown fox."""
		\\d = 'C:\\Users\\x'
		\\e = '''
		\\raw \\n line'''
		\\f = """two quotes at the end"\\""""
		\\g = ''''quoted' '''
	expected : TomlValue
	expected = Table([
		("a", String("tab\there \"q\" é 😀")),
		("b", String("Roses\nViolets")),
		("c", String("The quick brown fox.")),
		("d", String("C:\\Users\\x")),
		("e", String("raw \\n line")),
		("f", String("two quotes at the end\"\"")),
		("g", String("'quoted' ")),
	])
	TomlParse.parse(text) == Ok(expected)
}

# Integers in every base, with underscores and signs.
expect {
	text =
		\\a = +99
		\\b = -17
		\\c = 0
		\\d = 1_000_000
		\\e = 0xDEAD_beef
		\\f = 0o755
		\\g = 0b1101
		\\h = 9223372036854775807
		\\i = -9223372036854775808
	expected : TomlValue
	expected = Table([
		("a", Integer(99)),
		("b", Integer(-17)),
		("c", Integer(0)),
		("d", Integer(1000000)),
		("e", Integer(3735928559)),
		("f", Integer(493)),
		("g", Integer(13)),
		("h", Integer(9223372036854775807)),
		("i", Integer(-9223372036854775808)),
	])
	TomlParse.parse(text) == Ok(expected)
}

expect {
	text =
		\\a = 3.1415
		\\b = -0.01
		\\c = 5e+22
		\\d = 1e06
		\\e = -2E-2
		\\f = 6.626e-34
		\\g = 224_617.445_991
		\\h = inf
		\\i = -inf
	expected : TomlValue
	expected = Table([
		("a", Float(3.1415)),
		("b", Float(-0.01)),
		("c", Float(5e22)),
		("d", Float(1e6)),
		("e", Float(-0.02)),
		("f", Float(6.626e-34)),
		("g", Float(224617.445991)),
		("h", Float(F64.infinity)),
		("i", Float(-F64.infinity)),
	])
	TomlParse.parse(text) == Ok(expected)
}

expect
	match TomlParse.parse("x = nan") {
		Ok(value) =>
			match value.get("x") {
				Ok(Float(number)) => number.is_nan()
				_ => Bool.False
			}
		Err(_) => Bool.False
	}

# Date-times: all four forms; the original text is kept.
expect {
	text =
		\\a = 1979-05-27T07:32:00Z
		\\b = 1979-05-27T00:32:00.999999-07:00
		\\c = 1979-05-27 07:32:00
		\\d = 1979-05-27
		\\e = 00:32:00.5
	date = { year: 1979, month: 5, day: 27 }
	expected : TomlValue
	expected = Table([
		("a", OffsetDateTime({ date, time: { hour: 7, minute: 32, second: 0, nanosecond: 0 }, offset_minutes: 0, text: "1979-05-27T07:32:00Z" })),
		("b", OffsetDateTime({ date, time: { hour: 0, minute: 32, second: 0, nanosecond: 999_999_000 }, offset_minutes: -420, text: "1979-05-27T00:32:00.999999-07:00" })),
		("c", LocalDateTime({ date, time: { hour: 7, minute: 32, second: 0, nanosecond: 0 }, text: "1979-05-27 07:32:00" })),
		("d", LocalDate({ date, text: "1979-05-27" })),
		("e", LocalTime({ time: { hour: 0, minute: 32, second: 0, nanosecond: 500_000_000 }, text: "00:32:00.5" })),
	])
	TomlParse.parse(text) == Ok(expected)
}

# Arrays across lines, with comments and a trailing comma; mixed types.
expect {
	text =
		\\a = [
		\\  1, # one
		\\  "two",
		\\  [3],
		\\]
		\\b = []
	expected : TomlValue
	expected = Table([
		("a", Array([Integer(1), String("two"), Array([Integer(3)])])),
		("b", Array([])),
	])
	TomlParse.parse(text) == Ok(expected)
}

# Tables: implicit parents defined later, sub-tables after the parent.
expect {
	text =
		\\[x.y.z]
		\\a = 1
		\\[x]
		\\b = 2
		\\[x.w]
		\\c = 3
	expected : TomlValue
	expected = Table([("x", Table([("y", Table([("z", Table([("a", Integer(1))]))])), ("b", Integer(2)), ("w", Table([("c", Integer(3))]))]))])
	TomlParse.parse(text) == Ok(expected)
}

# Arrays of tables, with sub-tables going to the last element.
expect {
	text =
		\\[[fruits]]
		\\name = "apple"
		\\[fruits.physical]
		\\color = "red"
		\\[[fruits.varieties]]
		\\name = "red delicious"
		\\[[fruits]]
		\\name = "banana"
	expected : TomlValue
	expected = Table([
		("fruits", Array([
			Table([
				("name", String("apple")),
				("physical", Table([("color", String("red"))])),
				("varieties", Array([Table([("name", String("red delicious"))])])),
			]),
			Table([("name", String("banana"))]),
		])),
	])
	TomlParse.parse(text) == Ok(expected)
}

expect {
	text = "a = { b.c = 1, d = { e = 2 } }\r\nf = 'g'\r\n"
	expected : TomlValue
	expected = Table([("a", Table([("b", Table([("c", Integer(1))])), ("d", Table([("e", Integer(2))]))])), ("f", String("g"))])
	TomlParse.parse(text) == Ok(expected)
}

# Invalid documents.
expect is_syntax_error("a = 1\na = 2")
expect is_syntax_error("a.b = 1\na.b.c = 2")
expect is_syntax_error("[a]\n[a]")
expect is_syntax_error("[a]\nb = 1\n[a.b]")
expect is_syntax_error("a = {}\n[a]")
expect is_syntax_error("a = { b = 1 }\na.c = 2")
expect is_syntax_error("[a]\nb.c = 1\n[a.b]")
expect is_syntax_error("[[a]]\n[a]")
expect is_syntax_error("a = []\n[[a]]")
expect is_syntax_error("a = 1 b = 2")
expect is_syntax_error("a =")
expect is_syntax_error("= 1")
expect is_syntax_error("a = \"open")
expect is_syntax_error("a = \"bad \\q\"")
expect is_syntax_error("a = \"\\uD800\"")
expect is_syntax_error("a = 'new\nline'")
expect is_syntax_error("a = 01")
expect is_syntax_error("a = 1__0")
expect is_syntax_error("a = _1")
expect is_syntax_error("a = +0x10")
expect is_syntax_error("a = 0xG")
expect is_syntax_error("a = 9223372036854775808")
expect is_syntax_error("a = 1.")
expect is_syntax_error("a = .5")
expect is_syntax_error("a = 1e")
expect is_syntax_error("a = 1979-02-29")
expect is_syntax_error("a = 1979-05-27T25:00:00")
expect is_syntax_error("a = 1979-05-27T07:32:00+7:00")
expect is_syntax_error("a = [1 2]")
expect is_syntax_error("a = { b = 1, }")
expect is_syntax_error("a = { b = 1\n}")
expect is_syntax_error("[a\nb = 1")
expect is_syntax_error("a = tru")
expect is_syntax_error("a = 1 # bad \u(0001) control")

expect
	TomlParse.parse("a = 1\n\nb = 1\nb = 2") == Err(TomlSyntax("line 4: key b is defined twice"))

# A header may add a sub-table under a table defined by dotted keys.
expect {
	text =
		\\[fruit]
		\\apple.color = "red"
		\\[fruit.apple.texture]
		\\smooth = true
	expected : TomlValue
	expected = Table([("fruit", Table([("apple", Table([("color", String("red")), ("texture", Table([("smooth", Boolean(Bool.True))]))]))]))])
	TomlParse.parse(text) == Ok(expected)
}

expect is_syntax_error("[fruit]\napple.color = \"red\"\n[fruit.apple]")
