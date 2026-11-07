import TomlValue
import TomlParse
import TomlDecode

## TOML 1.0: parse text into a `TomlValue` tree, lay one tree over another,
## and decode a tree into a Roc type.
##
## ```roc
## Settings : { name : Str, listen : { port : U16 } }
##
## settings : Try(Settings, _)
## settings = Toml.decode_str("name = \"api\"\n[listen]\nport = 8080")
## ```
##
## Decoding rejects keys the type does not have, and errors name the key path,
## such as `listen.port: expected an integer, found a string`. A key may be
## left out when its field is `Try(T, [Missing])`.
##
## Tags are written in snake_case: `level = "info"` for `Info`,
## `mode = "read_only"` for `ReadOnly`, `limit = { fixed = 3 }` for `Fixed(3)`.
##
## Date-times decode as `Str` (the text as written) or as `Toml.OffsetDateTime`,
## `Toml.LocalDateTime`, `Toml.LocalDate`, or `Toml.LocalTime`.
Toml := [].{
	OffsetDateTime := { date : TomlValue.Date, time : TomlValue.Time, offset_minutes : I16, text : Str }.{
		is_eq : _

		parser_for = |encoding| |state| {
			parsed = encoding.parse_str(state)?
			match TomlParse.date_time(parsed.value) {
				Ok(OffsetDateTime(value)) => Ok({ value: Toml.OffsetDateTime.(value), rest: parsed.rest })
				_ => Err(encoding.invalid_value(state))
			}
		}
	}

	LocalDateTime := { date : TomlValue.Date, time : TomlValue.Time, text : Str }.{
		is_eq : _

		parser_for = |encoding| |state| {
			parsed = encoding.parse_str(state)?
			match TomlParse.date_time(parsed.value) {
				Ok(LocalDateTime(value)) => Ok({ value: Toml.LocalDateTime.(value), rest: parsed.rest })
				_ => Err(encoding.invalid_value(state))
			}
		}
	}

	LocalDate := { date : TomlValue.Date, text : Str }.{
		is_eq : _

		parser_for = |encoding| |state| {
			parsed = encoding.parse_str(state)?
			match TomlParse.date_time(parsed.value) {
				Ok(LocalDate(value)) => Ok({ value: Toml.LocalDate.(value), rest: parsed.rest })
				_ => Err(encoding.invalid_value(state))
			}
		}
	}

	LocalTime := { time : TomlValue.Time, text : Str }.{
		is_eq : _

		parser_for = |encoding| |state| {
			parsed = encoding.parse_str(state)?
			match TomlParse.date_time(parsed.value) {
				Ok(LocalTime(value)) => Ok({ value: Toml.LocalTime.(value), rest: parsed.rest })
				_ => Err(encoding.invalid_value(state))
			}
		}
	}

	## Parses a whole document. Errors name the line.
	parse : Str -> Try(TomlValue, [TomlSyntax(Str)])
	parse = |text| TomlParse.parse(text)

	## `override` laid over `base`: tables merge key by key, recursively; any
	## other value in `override`, including an array, replaces the one in `base`.
	merge : TomlValue, TomlValue -> TomlValue
	merge = |base, override| TomlValue.merge(base, override)

	## Decodes a tree into the type the caller asks for.
	decode : TomlValue -> Try(a, [TomlDecode(Str), ..errs])
		where [
			a.parser_for : TomlDecode -> (TomlDecode.State -> Try({ value : a, rest : TomlDecode.State }, [TomlDecode(Str), ..errs])),
		]
	decode = |value| TomlDecode.decode(value)

	## Parses and decodes in one step.
	decode_str : Str -> Try(a, [TomlSyntax(Str), TomlDecode(Str), ..errs])
		where [
			a.parser_for : TomlDecode -> (TomlDecode.State -> Try({ value : a, rest : TomlDecode.State }, [TomlSyntax(Str), TomlDecode(Str), ..errs])),
		]
	decode_str = |text| {
		value = TomlParse.parse(text)?
		TomlDecode.decode(value)
	}
}

expect {
	text =
		\\name = "api"
		\\[listen]
		\\port = 8080
	result : Try({ name : Str, listen : { port : U16 } }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str(text)
	result == Ok({ name: "api", listen: { port: 8080 } })
}

# The override file changes only the keys it names.
expect {
	base = Toml.parse("[db]\nhost = \"localhost\"\nport = 5432\n[log]\nlevel = \"info\"") ?? Table([])
	local = Toml.parse("[db]\nhost = \"db.internal\"") ?? Table([])
	result : Try({ db : { host : Str, port : U16 }, log : { level : [Info, Debug] } }, [TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode(Toml.merge(base, local))
	result == Ok({ db: { host: "db.internal", port: 5432 }, log: { level: Info } })
}

expect {
	result : Try({ port : U16 }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str("port = 80\nprot = 81")
	result == Err(TomlDecode("prot: unknown key"))
}

expect {
	result : Try({ port : U16 }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str("port = ")
	result == Err(TomlSyntax("line 1: expected a value"))
}

expect {
	text =
		\\at = 1979-05-27T07:32:00-08:00
		\\day = 1979-05-27
		\\local = 1979-05-27T07:32:00
		\\alarm = 07:30:00
		\\raw = 1979-05-27
	result : Try({ at : Toml.OffsetDateTime, day : Toml.LocalDate, local : Toml.LocalDateTime, alarm : Toml.LocalTime, raw : Str }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str(text)
	match result {
		Ok(decoded) =>
			decoded.at.offset_minutes == -480
			and decoded.at.time.hour == 7
			and decoded.day.date.year == 1979
			and decoded.local.text == "1979-05-27T07:32:00"
			and decoded.alarm.time.minute == 30
			and decoded.raw == "1979-05-27"
		Err(_) => Bool.False
	}
}

# A date where a date-time with an offset is expected.
expect {
	result : Try({ at : Toml.OffsetDateTime }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str("at = 1979-05-27")
	result == Err(TomlDecode("at: invalid value"))
}

# Counted lists: zero is the lower bound, one is its nearest valid neighbor,
# and two exercises advancing between elements. The following field must
# remain readable in all cases; negative list lengths are not valid inputs.
expect {
	[([], "[]"), ([1], "[1]"), ([1, 2], "[1, 2]")].all(
		|(items, text)| {
			result : Try({ first : List(U8), second : U16 }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
			result = Toml.decode_str("first = ${text}\nsecond = 80")
			result == Ok({ first: items, second: 80 })
		},
	)
}

# Empty lists in first, middle, and last position must return to the parent.
expect {
	result : Try({ lists : List(List(U8)), second : U16 }, [TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)])
	result = Toml.decode_str("lists = [[], [1], [], [2], []]\nsecond = 80")
	result == Ok({ lists: [[], [1], [], [2], []], second: 80 })
}
