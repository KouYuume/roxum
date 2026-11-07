## Reading `Accept-Encoding`. Platform code only.
ContentCoding := [].{

	## The content codings a client accepts, from `Accept-Encoding`: those
	## listed without `q=0`.
	accepts : Str, Str -> Bool
	accepts = |header, coding| {
		items = Str.split_on(header, ",").map(
			|item| {
				parts = Str.split_on(Str.trim(item), ";")
				name = lower(Str.trim(List.first(parts) ?? ""))
				{ name, accepted: !List.any(List.drop_first(parts, 1), is_zero_quality) }
			},
		)
		explicit = List.keep_if(items, |item| item.name == coding)
		if List.is_empty(explicit) {
			List.any(items, |item| item.name == "*" and item.accepted)
		} else {
			List.any(explicit, |item| item.accepted)
		}
	}
}

## Whether a parameter is `q=0`, `q=0.0`, or the like: not accepted.
is_zero_quality : Str -> Bool
is_zero_quality = |parameter| {
	compact = lower(Str.replace_each(Str.trim(parameter), " ", ""))
	if Str.starts_with(compact, "q=") {
		match Str.to_utf8(Str.drop_prefix(compact, "q=")) {
			['0'] => Bool.True
			['0', '.', .. as rest] => List.all(rest, |digit| digit == '0')
			_ => Bool.False
		}
	} else {
		Bool.False
	}
}

lower : Str -> Str
lower = |text| Str.from_utf8_lossy(
	List.map(
		Str.to_utf8(text),
		|byte| if byte >= 'A' and byte <= 'Z' {
			byte + 32
		} else {
			byte
		},
	),
)

expect ContentCoding.accepts("gzip, deflate, br", "br")
expect ContentCoding.accepts("gzip;q=0.5", "gzip")
expect !ContentCoding.accepts("br;q=0, gzip", "br")
expect !ContentCoding.accepts("gzip", "br")
expect !ContentCoding.accepts("br; Q=0.000", "br")
expect ContentCoding.accepts("br;q=0.001", "br")
expect ContentCoding.accepts("*", "br")
expect !ContentCoding.accepts("", "gzip")

# Explicit refusal wins over a wildcard, in either field-value order.
expect !ContentCoding.accepts("gzip;q=0, *;q=1", "gzip")
expect !ContentCoding.accepts("*;q=1, GZip;q=0.000", "gzip")
# Explicit acceptance wins over a refusing wildcard; absent codings use it.
expect ContentCoding.accepts("*;q=0, gzip;q=0.001", "gzip")
expect !ContentCoding.accepts("*;q=0", "gzip")
expect ContentCoding.accepts("br;q=0, *;q=1", "gzip")
