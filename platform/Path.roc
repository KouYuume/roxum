import PercentEncoding

## A route's pattern as a value, for registering the route and building links to
## it from one place:
##
## ```roc
## article = Path.new("/articles/{id}")
##
## Router.route(router, Path.pattern(article), MethodRouter.get(show))
## link = Path.url(article, { id: 42.U64 })   # Ok("/articles/42")
## ```
Path :: Str.{
	## Makes a path from `pattern`, written as for `Router.route`. Crashes on a
	## malformed one, which at the top level fails when the app is built.
	new : Str -> Path
	new = |text|
		match parts_of(text) {
			Ok(_) => Path.(text)
			Err(_) => crash "roxum Path: invalid route pattern `${text}`"
		}

	## The pattern, for `Router.route`.
	pattern : Path -> Str
	pattern = |Path.(text)| text

	## The path with each parameter filled in from the record `params`, whose
	## fields hold a `Str`, an integer, a `Dec`, or a `Bool`. Values are
	## percent-encoded, so one cannot add a segment; the slashes of a `{*rest}` value
	## separate segments. Fails for a parameter with no value (`MissingParam`), a
	## value for no parameter (`UnknownParam`), or a value the router would refuse:
	## empty, `.`, or `..` (`InvalidValue`).
	url : Path, params -> Try(Str, [MissingParam(Str), UnknownParam(Str), InvalidValue(Str)])
		where [params.encoder_for : Path.Format -> (params, Path.Values -> Try(Path.Values, []))]
	url = |path, params| {
		Shape : params
		encode_params = Shape.encoder_for(Path.Format.Default)
		Ok(encoded) = encode_params(params, Path.Values.{ field: "", entries: [] })
		fill(path, encoded.entries)
	}

	## The record's fields as text, so far.
	Values := { field : Str, entries : List((Str, Str)) }

	## The format that reads a record of values for `url`.
	Format := [Default].{
		rename_field : Path.Format, Str -> Str
		rename_field = |_, name| name

		encode_record : Path.Values, U64, (Path.Values, (Path.Values, Str, (Path.Values -> Try(Path.Values, [])) -> Try(Path.Values, [])) -> Try(Path.Values, [])) -> Try(Path.Values, [])
		encode_record = |state, _, write_fields| write_fields(state, |fields, name, write_value| write_value({ ..fields, field: name }))

		encode_str : Str, Path.Values -> Try(Path.Values, [])
		encode_str = |value, state| Ok({ ..state, entries: List.append(state.entries, (state.field, value)) })

		encode_bool : Bool, Path.Values -> Try(Path.Values, [])
		encode_bool = |value, state| Path.Format.encode_str(if value { "true" } else { "false" }, state)

		encode_dec : Dec, Path.Values -> Try(Path.Values, [])
		encode_dec = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_u8 : U8, Path.Values -> Try(Path.Values, [])
		encode_u8 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_i8 : I8, Path.Values -> Try(Path.Values, [])
		encode_i8 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_u16 : U16, Path.Values -> Try(Path.Values, [])
		encode_u16 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_i16 : I16, Path.Values -> Try(Path.Values, [])
		encode_i16 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_u32 : U32, Path.Values -> Try(Path.Values, [])
		encode_u32 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_i32 : I32, Path.Values -> Try(Path.Values, [])
		encode_i32 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_u64 : U64, Path.Values -> Try(Path.Values, [])
		encode_u64 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_i64 : I64, Path.Values -> Try(Path.Values, [])
		encode_i64 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_u128 : U128, Path.Values -> Try(Path.Values, [])
		encode_u128 = |value, state| Path.Format.encode_str(value.to_str(), state)

		encode_i128 : I128, Path.Values -> Try(Path.Values, [])
		encode_i128 = |value, state| Path.Format.encode_str(value.to_str(), state)
	}
}

fill : Path, List((Str, Str)) -> Try(Str, [MissingParam(Str), UnknownParam(Str), InvalidValue(Str)])
fill = |path, values| {
	text = Path.pattern(path)
	parts = match parts_of(text) {
		Ok(found) => found
		Err(_) => crash "roxum Path: invalid route pattern `${text}`"
	}
	for (name, _) in values {
		known = List.any(parts, |part| part == Param(name) or part == Rest(name))
		if !known { return Err(UnknownParam(name)) }
	}
	var $built = ""
	for part in parts {
		piece = match part {
			Literal(value) => value
			Param(name) => {
				value = value_of(values, name)?
				encode_segment(value, name)?
			}
			Rest(name) => {
				value = value_of(values, name)?
				var $encoded = []
				for segment in Str.split_on(value, "/") {
					$encoded = List.append($encoded, encode_segment(segment, name)?)
				}
				Str.join_with($encoded, "/")
			}
		}
		$built = "${$built}/${piece}"
	}
	Ok(if Str.is_empty($built) { "/" } else { $built })
}

parts_of = |text| {
	if !Str.starts_with(text, "/") { return Err(Invalid) }
	var $parts = []
	for segment in List.drop_first(Str.split_on(text, "/"), 1) {
		if Str.starts_with(segment, "{*") and Str.ends_with(segment, "}") {
			$parts = List.append($parts, Rest(name_between(segment, 2)))
		} else if Str.starts_with(segment, "{") and Str.ends_with(segment, "}") {
			$parts = List.append($parts, Param(name_between(segment, 1)))
		} else if Str.contains(segment, "{") or Str.contains(segment, "}") {
			return Err(Invalid)
		} else if segment != "" {
			$parts = List.append($parts, Literal(segment))
		} else if $parts != [] {
			# A trailing slash stays significant.
			$parts = List.append($parts, Literal(""))
		}
	}
	Ok($parts)
}

name_between = |segment, skip| {
	bytes = List.drop_first(segment.to_utf8(), skip)
	Str.from_utf8_lossy(List.take_first(bytes, List.len(bytes) - 1))
}

value_of = |values, name|
	match List.find_first(values, |(key, _)| key == name) {
		Ok((_, value)) => Ok(value)
		Err(_) => Err(MissingParam(name))
	}

encode_segment = |value, name|
	if value == "" or value == "." or value == ".." {
		Err(InvalidValue(name))
	} else {
		Ok(PercentEncoding.encode(value))
	}

article = Path.new("/articles/{id}")

expect Path.pattern(article) == "/articles/{id}"
expect Path.url(article, { id: "42" }) == Ok("/articles/42")
# A value of any type that is a path segment, across the integer types' ends.
expect Path.url(article, { id: 42.U64 }) == Ok("/articles/42")
expect Path.url(article, { id: 0.U8 }) == Ok("/articles/0")
expect Path.url(article, { id: -1.I64 }) == Ok("/articles/-1")
expect Path.url(article, { id: 340282366920938463463374607431768211455.U128 }) == Ok("/articles/340282366920938463463374607431768211455")
expect Path.url(article, { id: 1.5.Dec }) == Ok("/articles/1.5")
expect Path.url(article, { id: Bool.True }) == Ok("/articles/true")
# A value cannot add a segment or leave the path.
expect Path.url(article, { id: "a/b c" }) == Ok("/articles/a%2Fb%20c")
expect Path.url(article, { id: "鵬" }) == Ok("/articles/%E9%B5%AC")
expect Path.url(article, {}) == Err(MissingParam("id"))
expect Path.url(article, { idd: "1" }) == Err(UnknownParam("idd"))
expect Path.url(article, { id: "1", other: "2" }) == Err(UnknownParam("other"))
expect Path.url(article, { id: "" }) == Err(InvalidValue("id"))
expect Path.url(article, { id: "." }) == Err(InvalidValue("id"))
expect Path.url(article, { id: ".." }) == Err(InvalidValue("id"))
# A value that is not in a record has no name.
expect Path.url(article, "1") == Err(UnknownParam(""))
expect Path.url(article, { id: { nested: "1" } }) == Err(UnknownParam("nested"))
expect Path.url(Path.new("/"), {}) == Ok("/")
expect Path.url(Path.new("/users/"), {}) == Ok("/users/")
expect Path.url(Path.new("/orgs/{org}/users/{id}"), { id: 2.U64, org: "a" }) == Ok("/orgs/a/users/2")
expect Path.url(Path.new("/files/{*rest}"), { rest: "a b/c" }) == Ok("/files/a%20b/c")
expect Path.url(Path.new("/files/{*rest}"), { rest: "a/../b" }) == Err(InvalidValue("rest"))
