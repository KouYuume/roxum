## A parsed TOML document: a tree of values. Tables keep their keys in the
## order the document wrote them.
TomlValue := [
	String(Str),
	Integer(I64),
	Float(F64),
	Boolean(Bool),
	OffsetDateTime({ date : TomlValue.Date, time : TomlValue.Time, offset_minutes : I16, text : Str }),
	LocalDateTime({ date : TomlValue.Date, time : TomlValue.Time, text : Str }),
	LocalDate({ date : TomlValue.Date, text : Str }),
	LocalTime({ time : TomlValue.Time, text : Str }),
	Array(List(TomlValue)),
	Table(List((Str, TomlValue))),
].{
	is_eq : _

	Date : { year : U16, month : U8, day : U8 }

	Time : { hour : U8, minute : U8, second : U8, nanosecond : U32 }

	## The value at `key` in a table.
	get : TomlValue, Str -> Try(TomlValue, [NotFound])
	get = |value, key|
		match value {
			Table(entries) =>
				match entries.find_first(|(name, _)| name == key) {
					Ok((_, found)) => Ok(found)
					Err(_) => Err(NotFound)
				}
			_ => Err(NotFound)
		}

	## `override` laid over `base`: tables are merged key by key, recursively;
	## any other value in `override` replaces the one in `base`.
	merge : TomlValue, TomlValue -> TomlValue
	merge = |base, override|
		match (base, override) {
			(Table(base_entries), Table(override_entries)) => {
				var $merged = base_entries
				for (key, value) in override_entries {
					$merged = match $merged.find_first_index(|(name, _)| name == key) {
						Ok(index) => {
							(_, existing) = $merged.get(index) ?? (key, value)
							$merged.set(index, (key, TomlValue.merge(existing, value))) ?? $merged
						}
						Err(_) => $merged.append((key, value))
					}
				}
				Table($merged)
			}
			_ => override
		}

	## A word for the kind of value, for error messages.
	kind : TomlValue -> Str
	kind = |value|
		match value {
			String(_) => "a string"
			Integer(_) => "an integer"
			Float(_) => "a float"
			Boolean(_) => "a boolean"
			OffsetDateTime(_) => "an offset date-time"
			LocalDateTime(_) => "a local date-time"
			LocalDate(_) => "a local date"
			LocalTime(_) => "a local time"
			Array(_) => "an array"
			Table(_) => "a table"
		}
}

expect {
	base : TomlValue
	base = Table([("port", Integer(80)), ("db", Table([("host", String("a")), ("user", String("u"))]))])
	override : TomlValue
	override = Table([("db", Table([("host", String("b"))])), ("debug", Boolean(Bool.True))])
	TomlValue.merge(base, override) == Table([("port", Integer(80)), ("db", Table([("host", String("b")), ("user", String("u"))])), ("debug", Boolean(Bool.True))])
}

expect {
	base : TomlValue
	base = Table([("hosts", Array([String("a"), String("b")]))])
	override : TomlValue
	override = Table([("hosts", Array([String("c")]))])
	TomlValue.merge(base, override) == Table([("hosts", Array([String("c")]))])
}
