## PostgreSQL frontend/backend protocol 3.0: building frontend messages and
## splitting backend ones. Bytes only, no I/O.
PgProtocol := [].{
	## A value bound to `$1`, `$2`, ... in text format; `Null` is SQL NULL.
	Text := [Null, Value(List(U8))].{
		is_eq : _
	}

	## A column of a RowDescription: its name and type OID.
	Column : { name : Str, type_oid : U32 }

	## The first message on a new connection. Settings such as
	## `application_name` go in `parameters`.
	startup : List((Str, Str)) -> List(U8)
	startup = |parameters| {
		var $body = be32(196608)
		for (name, value) in parameters {
			$body = $body.concat(cstring(name)).concat(cstring(value))
		}
		body = $body.append(0)
		be32((body.len() + 4).to_u32_wrap()).concat(body)
	}

	## Asks the server to switch to TLS; it answers one byte, `S` or `N`.
	ssl_request : List(U8)
	ssl_request = be32(8).concat(be32(80877103))

	sasl_initial : Str, List(U8) -> List(U8)
	sasl_initial = |mechanism, data| message('p', cstring(mechanism).concat(be32(data.len().to_u32_wrap())).concat(data))

	sasl_response : List(U8) -> List(U8)
	sasl_response = |data| message('p', data)

	## One statement with its parameters in the extended query protocol:
	## Parse, Bind, Describe, Execute, and Sync. The server infers the
	## parameter types; values and results are text.
	extended_query : Str, List(PgProtocol.Text) -> List(U8)
	extended_query = |sql, values| {
		parse = message('P', cstring("").concat(cstring(sql)).concat(be16(0)))
		var $bound = []
		for value in values {
			$bound = match value {
				Null => $bound.concat(be32(0xffffffff))
				Value(bytes) => $bound.concat(be32(bytes.len().to_u32_wrap())).concat(bytes)
			}
		}
		bound = $bound
		bind = message('B', cstring("").concat(cstring("")).concat(be16(0)).concat(be16(values.len().to_u16_wrap())).concat(bound).concat(be16(0)))
		describe = message('D', ['P'].concat(cstring("")))
		execute = message('E', cstring("").concat(be32(0)))
		parse.concat(bind).concat(describe).concat(execute).concat(sync)
	}

	## A statement without parameters, such as `BEGIN`, in the simple query
	## protocol.
	simple_query : Str -> List(U8)
	simple_query = |sql| message('Q', cstring(sql))

	terminate : List(U8)
	terminate = message('X', [])

	## Splits the first complete backend message off `buffer`.
	next_message : List(U8) -> [Message({ kind : U8, body : List(U8) }, List(U8)), NeedMore, Malformed]
	next_message = |buffer| {
		if buffer.len() < 5 {
			return NeedMore
		}
		kind = buffer.get(0) ?? 0
		length = read32(buffer, 1).to_u64()
		if length < 4 {
			return Malformed
		}
		total = length + 1
		if buffer.len() < total {
			NeedMore
		} else {
			Message({ kind, body: buffer.sublist({ start: 5, len: length - 4 }) }, buffer.drop_first(total))
		}
	}

	auth_code : List(U8) -> U32
	auth_code = |body| read32(body, 0)

	## The SASL mechanisms of an AuthenticationSASL body.
	sasl_mechanisms : List(U8) -> List(Str)
	sasl_mechanisms = |body| cstrings(body.drop_first(4))

	## A field of an ErrorResponse or NoticeResponse, such as `M` (message),
	## `C` (SQLSTATE code), or `n` (constraint name); empty when absent.
	error_field : List(U8), U8 -> Str
	error_field = |body, wanted| {
		var $index = 0
		var $found = ""
		while $index < body.len() {
			code = body.get($index) ?? 0
			if code == 0 {
				break
			}
			rest = body.drop_first($index + 1)
			end = rest.find_first_index(|byte| byte == 0) ?? rest.len()
			if code == wanted {
				$found = Str.from_utf8(rest.take_first(end)) ?? ""
			}
			$index = $index + 1 + end + 1
		}
		$found
	}

	## The columns of a RowDescription body.
	row_description : List(U8) -> List(PgProtocol.Column)
	row_description = |body| {
		count = read16(body, 0)
		var $offset = 2
		var $columns = []
		var $column = 0
		while $column < count {
			rest = body.drop_first($offset)
			end = rest.find_first_index(|byte| byte == 0) ?? rest.len()
			name = Str.from_utf8(rest.take_first(end)) ?? "?"
			# After the name: table OID (4), column number (2), type OID (4),
			# type size (2), type modifier (4), and format (2).
			type_oid = read32(body, $offset + end + 1 + 6)
			$columns = $columns.append({ name, type_oid })
			$offset = $offset + end + 1 + 18
			$column = $column + 1
		}
		$columns
	}

	## The values of a DataRow body, in text format.
	data_row : List(U8) -> List(PgProtocol.Text)
	data_row = |body| {
		count = read16(body, 0)
		var $offset = 2
		var $values = []
		var $column = 0
		while $column < count {
			length = read32(body, $offset)
			if length == 0xffffffff {
				$values = $values.append(Null)
				$offset = $offset + 4
			} else {
				$values = $values.append(Value(body.sublist({ start: $offset + 4, len: length.to_u64() })))
				$offset = $offset + 4 + length.to_u64()
			}
			$column = $column + 1
		}
		$values
	}

	## The number of rows a CommandComplete tag reports, such as 3 for
	## `UPDATE 3` or 1 for `INSERT 0 1`; 0 for tags without one.
	affected_rows : List(U8) -> U64
	affected_rows = |body| {
		tag = command_tag(body)
		match tag.split_on(" ").last() {
			Ok(last) => U64.from_str(last) ?? 0
			Err(_) => 0
		}
	}

	command_tag : List(U8) -> Str
	command_tag = |body| Str.from_utf8(body.take_first(body.find_first_index(|byte| byte == 0) ?? body.len())) ?? ""
}

sync : List(U8)
sync = message('S', [])

message : U8, List(U8) -> List(U8)
message = |kind, body| [kind].concat(be32((body.len() + 4).to_u32_wrap())).concat(body)

cstring : Str -> List(U8)
cstring = |text| text.to_utf8().append(0)

cstrings : List(U8) -> List(Str)
cstrings = |bytes| {
	var $rest = bytes
	var $found = []
	while Bool.True {
		end = $rest.find_first_index(|byte| byte == 0) ?? $rest.len()
		if end == 0 {
			break
		}
		$found = $found.append(Str.from_utf8($rest.take_first(end)) ?? "")
		$rest = $rest.drop_first(end + 1)
	}
	$found
}

be16 : U16 -> List(U8)
be16 = |value| [value.shr_zf_wrap(8).to_u8_wrap(), value.to_u8_wrap()]

be32 : U32 -> List(U8)
be32 = |value| [
	value.shr_zf_wrap(24).to_u8_wrap(),
	value.shr_zf_wrap(16).to_u8_wrap(),
	value.shr_zf_wrap(8).to_u8_wrap(),
	value.to_u8_wrap(),
]

read32 : List(U8), U64 -> U32
read32 = |bytes, index| {
	b0 = (bytes.get(index) ?? 0).to_u32()
	b1 = (bytes.get(index + 1) ?? 0).to_u32()
	b2 = (bytes.get(index + 2) ?? 0).to_u32()
	b3 = (bytes.get(index + 3) ?? 0).to_u32()
	b0.shl_wrap(24).bitwise_or(b1.shl_wrap(16)).bitwise_or(b2.shl_wrap(8)).bitwise_or(b3)
}

read16 : List(U8), U64 -> U64
read16 = |bytes, index| (bytes.get(index) ?? 0).to_u64() * 256 + (bytes.get(index + 1) ?? 0).to_u64()

expect PgProtocol.simple_query("BEGIN") == ['Q', 0, 0, 0, 10, 'B', 'E', 'G', 'I', 'N', 0]
expect PgProtocol.ssl_request == [0, 0, 0, 8, 4, 210, 22, 47]
expect PgProtocol.next_message(['Z', 0, 0, 0, 5, 'I', 'x']) == Message({ kind: 'Z', body: ['I'] }, ['x'])
expect PgProtocol.next_message(['Z', 0, 0, 0, 5]) == NeedMore
expect PgProtocol.next_message(['Z', 0, 0, 0, 3, 0]) == Malformed
expect PgProtocol.error_field(['S', 'E', 0, 'C', '2', '3', '5', '0', '5', 0, 'M', 'h', 'i', 0, 0], 'C') == "23505"
expect PgProtocol.data_row([0, 2, 0, 0, 0, 1, '7', 255, 255, 255, 255]) == [Value(['7']), Null]
expect PgProtocol.affected_rows("INSERT 0 3".to_utf8().append(0)) == 3
expect PgProtocol.affected_rows("UPDATE 12".to_utf8().append(0)) == 12
expect PgProtocol.affected_rows("BEGIN".to_utf8().append(0)) == 0
expect PgProtocol.sasl_mechanisms([0, 0, 0, 10, 'A', 0, 'B', 'C', 0, 0]) == ["A", "BC"]

# RowDescription with one column `id` of type int8 (OID 20).
expect {
	body = [0, 1, 'i', 'd', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 8, 255, 255, 255, 255, 0, 0]
	PgProtocol.row_description(body) == [{ name: "id", type_oid: 20 }]
}

# Every byte of a statement without parameters.
expect PgProtocol.extended_query("S", []) == [
	'P', 0, 0, 0, 9, 0, 'S', 0, 0, 0,
	'B', 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0,
	'D', 0, 0, 0, 6, 'P', 0,
	'E', 0, 0, 0, 9, 0, 0, 0, 0, 0,
	'S', 0, 0, 0, 4,
]

# Every byte of the Bind for one value and one NULL.
expect {
	bytes = PgProtocol.extended_query("S", [Value(['7']), Null])
	bytes.sublist({ start: 10, len: 22 }) == ['B', 0, 0, 0, 21, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, '7', 255, 255, 255, 255, 0, 0]
}

# Parse with the SQL and no declared types, then Bind with one NULL and one
# text value, Describe, Execute, Sync.
expect {
	bytes = PgProtocol.extended_query("SELECT $1, $2", [Null, Value(['7'])])
	parse_length = 4 + 1 + 14 + 2
	bind = bytes.drop_first(1 + parse_length)
	bytes.get(0) == Ok('P')
	and bind.get(0) == Ok('B')
	and bind.sublist({ start: 5, len: 10 }) == [0, 0, 0, 0, 0, 2, 255, 255, 255, 255]
	and bytes.take_last(5) == ['S', 0, 0, 0, 4]
}
