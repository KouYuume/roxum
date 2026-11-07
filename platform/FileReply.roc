import Compression
import ContentCoding
import FileRoot
import HeaderValue
import HostFiles
import HostStream
import Http

## Sends the file of a `Reply.file`, after the middleware. The host
## only opens files, tells their size and time, and sends a range of one;
## what the response is, from the request's headers, is decided here.
## Platform code only.
FileReply := [].{
	## Opens the file and sends it with `response`'s status and headers;
	## returns the response for the host to send, or the head of the one
	## already sent.
	## With `compression` from `Compression.layer`, a file sent whole is
	## gzip-compressed as it goes unless a precompressed one is.
	send! : Http.Request, Http.Response, { root : FileRoot, path : Str }, Try({ above_bytes : U64 }, [NotCompressible]) => Http.Response
	send! = |request, response, target, compression| {
		root = target.root
		path = relative(target.path)
		answer = match HostFiles.open!(FileRoot.handle(root), path) {
			HostFiles.FileOpened.Opened(entry) =>
				if !entry.directory {
					file_answer!(request, response, root, path, entry, compression)
				} else if Str.ends_with(request.path, "/") {
					index = if path == "" or Str.ends_with(path, "/") { "${path}index.html" } else { "${path}/index.html" }
					match HostFiles.open!(FileRoot.handle(root), index) {
						HostFiles.FileOpened.Opened(index_entry) =>
							if index_entry.directory {
								Missing
							} else {
								file_answer!(request, response, root, index, index_entry, compression)
							}
						HostFiles.FileOpened.NotFound => Missing
						HostFiles.FileOpened.Failed => Broken
					}
				} else {
					# Relative links in the directory's page resolve under it.
					query = if List.is_empty(request.query) { "" } else { "?${Str.from_utf8_lossy(request.query)}" }
					Redirect("${request.path}/${query}")
				}
			HostFiles.FileOpened.NotFound => Missing
			HostFiles.FileOpened.Failed => Broken
		}
		match answer {
			Missing => {
				HostFiles.close!({})
				{ ..response, status: 404, body: Http.ResponseBody.Empty }
			}
			Broken => {
				HostFiles.close!({})
				{ ..response, status: 500, body: Http.ResponseBody.Empty }
			}
			Redirect(location) => {
				HostFiles.close!({})
				{ ..response, status: 301, headers: with_header(response.headers, "location", location), body: Http.ResponseBody.Empty }
			}
			Answered(sent) => {
				HostFiles.close!({})
				sent
			}
		}
	}

	## The media type of a file, from its extension, for `content-type`.
	content_type : Str -> Str
	content_type = |path| {
		extension = match List.last(Str.split_on(last_segment(path), ".")) {
			Ok(last) => if last == last_segment(path) { "" } else { lower(last) }
			Err(_) => ""
		}
		match extension {
			"html" | "htm" => "text/html; charset=utf-8"
			"css" => "text/css; charset=utf-8"
			"js" | "mjs" => "text/javascript; charset=utf-8"
			"json" | "map" => "application/json"
			"txt" => "text/plain; charset=utf-8"
			"md" => "text/markdown; charset=utf-8"
			"csv" => "text/csv; charset=utf-8"
			"xml" => "application/xml"
			"svg" => "image/svg+xml"
			"png" => "image/png"
			"jpg" | "jpeg" => "image/jpeg"
			"gif" => "image/gif"
			"webp" => "image/webp"
			"avif" => "image/avif"
			"ico" => "image/x-icon"
			"woff" => "font/woff"
			"woff2" => "font/woff2"
			"ttf" => "font/ttf"
			"otf" => "font/otf"
			"pdf" => "application/pdf"
			"wasm" => "application/wasm"
			"mp4" => "video/mp4"
			"webm" => "video/webm"
			"mp3" => "audio/mpeg"
			"ogg" => "audio/ogg"
			"wav" => "audio/wav"
			"zip" => "application/zip"
			"gz" => "application/gzip"
			_ => "application/octet-stream"
		}
	}

	## A time as an HTTP date (IMF-fixdate), such as
	## `Sun, 06 Nov 1994 08:49:37 GMT`, from seconds since the Unix epoch.
	http_date : I64 -> Str
	http_date = |seconds| {
		clamped = if seconds < 0 { 0 } else { seconds }
		days = clamped // 86_400
		of_day = clamped % 86_400
		{ year, month, day } = civil_from_days(days)
		weekday = match (days + 4) % 7 {
			0 => "Sun"
			1 => "Mon"
			2 => "Tue"
			3 => "Wed"
			4 => "Thu"
			5 => "Fri"
			_ => "Sat"
		}
		month_name = match List.get(month_names, (month - 1).to_u64_wrap()) {
			Ok(name) => name
			Err(_) => "Jan"
		}
		"${weekday}, ${two(day)} ${month_name} ${year.to_str()} ${two(of_day // 3600)}:${two((of_day % 3600) // 60)}:${two(of_day % 60)} GMT"
	}

	## Seconds since the Unix epoch of an HTTP date in IMF-fixdate, the form
	## clients send back. Other forms are `Err(Invalid)`, and the header is
	## then ignored.
	parse_http_date : Str -> Try(I64, [Invalid])
	parse_http_date = |text| {
		bytes = Str.to_utf8(text)
		if List.len(bytes) != 29 or List.sublist(bytes, { start: 25, len: 4 }) != " GMT".to_utf8() {
			return Err(Invalid)
		}
		day = number(bytes, 5, 2)?
		month_text = Str.from_utf8_lossy(List.sublist(bytes, { start: 8, len: 3 }))
		month = match List.find_first_index(month_names, |name| name == month_text) {
			Ok(index) => index.to_i64_wrap() + 1
			Err(_) => return Err(Invalid)
		}
		year = number(bytes, 12, 4)?
		hour = number(bytes, 17, 2)?
		minute = number(bytes, 20, 2)?
		second = number(bytes, 23, 2)?
		if day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60 {
			return Err(Invalid)
		}
		Ok(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
	}

	## A weak validator from a file's size and time, and the content coding of
	## a precompressed one.
	etag : { size : U64, modified_seconds : I64, directory : Bool }, Str -> Str
	etag = |entry, coding| {
		suffix = if coding == "" { "" } else { "-${coding}" }
		"W/\"${hex(entry.size)}-${hex((if entry.modified_seconds < 0 { 0 } else { entry.modified_seconds }).to_u64_wrap())}${suffix}\""
	}

	## Whether a request with these validators already has the file: an
	## `If-None-Match` that names its ETag (compared weakly) or is `*`, or,
	## without one, an `If-Modified-Since` at or after its time.
	not_modified : { if_none_match : Try(Str, [Missing]), if_modified_since : Try(Str, [Missing]) }, Str, I64 -> Bool
	not_modified = |conditions, tag, modified_seconds|
		match conditions.if_none_match {
			Ok(list) =>
				List.any(
					Str.split_on(list, ","),
					|candidate| {
						trimmed = Str.trim(candidate)
						trimmed == "*" or weak(trimmed) == weak(tag)
					},
				)
			Err(Missing) =>
				match conditions.if_modified_since {
					Ok(date) =>
						match FileReply.parse_http_date(date) {
							Ok(since) => modified_seconds <= since
							Err(Invalid) => Bool.False
						}
					Err(Missing) => Bool.False
				}
		}

	## The one byte range a `Range` header asks of a file of `size` bytes:
	## `Whole` for anything but a single satisfiable or unsatisfiable range of
	## bytes (several ranges, another unit, or a malformed header are served
	## whole), `Part` for the bytes to send, `Unsatisfiable` for 416.
	range : Str, U64 -> [Whole, Part({ start : U64, length : U64 }), Unsatisfiable]
	range = |header, size| {
		spec = match strip_prefix(Str.trim(header), "bytes=") {
			Ok(rest) => Str.trim(rest)
			Err(_) => return Whole
		}
		if Str.contains(spec, ",") {
			return Whole
		}
		match Str.split_on(spec, "-") {
			["", suffix] =>
				match U64.from_str(suffix) {
					Ok(0) => Unsatisfiable
					Ok(length) =>
						if size == 0 {
							Unsatisfiable
						} else {
							taken = if length > size { size } else { length }
							Part({ start: size - taken, length: taken })
						}
					Err(_) => Whole
				}
			[first, last] =>
				match U64.from_str(first) {
					Err(_) => Whole
					Ok(start) =>
						if start >= size {
							Unsatisfiable
						} else if last == "" {
							Part({ start, length: size - start })
						} else {
							match U64.from_str(last) {
								Ok(end) =>
									if end < start {
										Whole
									} else {
										stop = if end >= size { size - 1 } else { end }
										Part({ start, length: stop - start + 1 })
									}
								Err(_) => Whole
							}
						}
				}
			_ => Whole
		}
	}
}

## A file opened under the root, or the precompressed one the client takes:
## its response, sent or to send.
file_answer! : Http.Request, Http.Response, FileRoot, Str, { size : U64, modified_seconds : I64, directory : Bool }, Try({ above_bytes : U64 }, [NotCompressible]) => [Answered(Http.Response), Missing, Broken, Redirect(Str)]
file_answer! = |request, response, root, path, entry, compression| {
	variants = FileRoot.precompressed(root)
	accepted = match header_value(request, "accept-encoding") {
		Ok(value) => value
		Err(Missing) => ""
	}
	(chosen, coding) = choose_variant!(root, path, entry, variants, accepted)
	tag = FileReply.etag(chosen, coding)
	last_modified = FileReply.http_date(chosen.modified_seconds)
	validated =
		with_content_type(response.headers, path)
		|> with_header("etag", tag)
		|> with_header("last-modified", last_modified)
		|> with_header("accept-ranges", "bytes")
	encoded = if coding == "" { validated } else { with_header(validated, "content-encoding", coding) }
	headers = if List.is_empty(variants) { encoded } else { with_header(encoded, "vary", "accept-encoding") }
	method_has_body = request.method == Http.Method.GET or request.method == Http.Method.HEAD
	conditions = {
		if_none_match: header_value(request, "if-none-match"),
		if_modified_since: header_value(request, "if-modified-since"),
	}
	if response.status == 200 and method_has_body and FileReply.not_modified(conditions, tag, chosen.modified_seconds) {
		return Answered({ ..response, status: 304, headers, body: Http.ResponseBody.Empty })
	}
	wanted = if response.status == 200 and request.method == Http.Method.GET and range_applies(request, last_modified) {
		match header_value(request, "range") {
			Ok(value) => FileReply.range(value, chosen.size)
			Err(Missing) => Whole
		}
	} else {
		Whole
	}
	match wanted {
		Unsatisfiable =>
			Answered(
				{
					..response,
					status: 416,
					headers: with_header(response.headers, "content-range", "bytes */${chosen.size.to_str()}"),
					body: Http.ResponseBody.Empty,
				},
			)
		Whole => {
			# A range is of the file's own bytes, so a ranged request is not
			# compressed; nor is a precompressed file again.
			planned = match compression {
				Ok(options) =>
					if coding == "" and header_value(request, "range") == Err(Missing) {
						Compression.plan(request, options, { ..response, headers }, Ok(chosen.size))
					} else {
						{ headers, gzip: Bool.False }
					}
				Err(NotCompressible) => { headers, gzip: Bool.False }
			}
			Answered(stream!(request, { ..response, headers: planned.headers }, 0, chosen.size, planned.gzip))
		}
		Part({ start, length }) => {
			partial = with_header(headers, "content-range", "bytes ${start.to_str()}-${(start + length - 1).to_str()}/${chosen.size.to_str()}")
			Answered(stream!(request, { ..response, status: 206, headers: partial }, start, length, Bool.False))
		}
	}
}

## Opens the first precompressed file beside `path` the client accepts; the
## original, opened again, when there is none.
choose_variant! : FileRoot, Str, { size : U64, modified_seconds : I64, directory : Bool }, List({ suffix : Str, coding : Str }), Str => ({ size : U64, modified_seconds : I64, directory : Bool }, Str)
choose_variant! = |root, path, entry, variants, accepted| {
	var $tried = Bool.False
	for variant in variants {
		if ContentCoding.accepts(accepted, variant.coding) {
			$tried = Bool.True
			match HostFiles.open!(FileRoot.handle(root), "${path}${variant.suffix}") {
				HostFiles.FileOpened.Opened(found) =>
					if !found.directory {
						return (found, variant.coding)
					}
				HostFiles.FileOpened.NotFound | HostFiles.FileOpened.Failed => {}
			}
		}
	}
	if $tried {
		# Opening a variant closed the original.
		match HostFiles.open!(FileRoot.handle(root), path) {
			HostFiles.FileOpened.Opened(again) => (again, "")
			HostFiles.FileOpened.NotFound | HostFiles.FileOpened.Failed => (entry, "")
		}
	} else {
		(entry, "")
	}
}

## Sends `length` bytes of the open file from `start` as the body of
## `response`: the head with `Content-Length`, then the bytes, unless the
## request is `HEAD`. With `gzip`, the host compresses them as they go, and
## the length is not known in the head.
stream! : Http.Request, Http.Response, U64, U64, Bool => Http.Response
stream! = |request, response, start, length, gzip| {
	head = { ..response, body: Http.ResponseBody.Empty }
	token = HostStream.start!(head, 0, [], Bool.False, if gzip { 18_446_744_073_709_551_615 } else { length }, gzip)
	if token != 0 and request.method != Http.Method.HEAD and length != 0 {
		_ = HostFiles.send!(token, start, length)
	}
	head
}

## Whether `Range` applies: without `If-Range`, or with one equal to the
## file's `Last-Modified`. The ETag is weak, so an entity tag in `If-Range`
## never matches it (RFC 9110 §13.1.5) and the file is sent whole.
range_applies : Http.Request, Str -> Bool
range_applies = |request, last_modified|
	match header_value(request, "if-range") {
		Ok(value) => Str.trim(value) == last_modified
		Err(Missing) => Bool.True
	}

header_value : Http.Request, Str -> Try(Str, [Missing])
header_value = |request, name|
	match List.find_first(request.headers, |header| Http.HeaderName.inner(header.name) == name) {
		Ok(header) => Ok(Str.from_utf8_lossy(header.value))
		Err(_) => Err(Missing)
	}

with_header : List(Http.ResponseHeader), Str, Str -> List(Http.ResponseHeader)
with_header = |headers, name, text|
	match HeaderValue.from_str(text) {
		Ok(value) => List.append(headers, Http.ResponseHeader.{ name: Http.HeaderName.(name), value })
		Err(CrlfInjection) => headers
	}

month_names : List(Str)
month_names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

## Year, month, and day of a count of days since 1970-01-01 (Howard
## Hinnant's `civil_from_days`).
civil_from_days : I64 -> { year : I64, month : I64, day : I64 }
civil_from_days = |days| {
	shifted = days + 719_468
	era = (if shifted >= 0 { shifted } else { shifted - 146_096 }) // 146_097
	day_of_era = shifted - era * 146_097
	year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36_524 - day_of_era // 146_096) // 365
	day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	month_index = (5 * day_of_year + 2) // 153
	day = day_of_year - (153 * month_index + 2) // 5 + 1
	month = if month_index < 10 { month_index + 3 } else { month_index - 9 }
	year = year_of_era + era * 400 + (if month <= 2 { 1 } else { 0 })
	{ year, month, day }
}

## Days since 1970-01-01 of a date (Howard Hinnant's `days_from_civil`).
days_from_civil : I64, I64, I64 -> I64
days_from_civil = |year, month, day| {
	shifted_year = if month <= 2 { year - 1 } else { year }
	era = (if shifted_year >= 0 { shifted_year } else { shifted_year - 399 }) // 400
	year_of_era = shifted_year - era * 400
	day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) // 5 + day - 1
	day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
	era * 146_097 + day_of_era - 719_468
}

number : List(U8), U64, U64 -> Try(I64, [Invalid])
number = |bytes, start, length|
	match I64.from_str(Str.from_utf8_lossy(List.sublist(bytes, { start, len: length }))) {
		Ok(value) => Ok(value)
		Err(_) => Err(Invalid)
	}

two : I64 -> Str
two = |value| if value < 10 { "0${value.to_str()}" } else { value.to_str() }

hex : U64 -> Str
hex = |value| {
	digits = "0123456789abcdef".to_utf8()
	var $rest = value
	var $text = []
	while $rest >= 16 {
		$text = List.prepend($text, List.get(digits, $rest % 16) ?? '0')
		$rest = $rest // 16
	}
	Str.from_utf8_lossy(List.prepend($text, List.get(digits, $rest) ?? '0'))
}

weak : Str -> Str
weak = |tag| match strip_prefix(tag, "W/") {
	Ok(rest) => rest
	Err(_) => tag
}

strip_prefix : Str, Str -> Try(Str, [NoPrefix])
strip_prefix = |text, prefix| if Str.starts_with(text, prefix) { Ok(Str.drop_prefix(text, prefix)) } else { Err(NoPrefix) }

## A path under the root: leading slashes, as in a URL path, are dropped.
relative : Str -> Str
relative = |path| {
	var $rest = path
	while Str.starts_with($rest, "/") {
		$rest = Str.drop_prefix($rest, "/")
	}
	$rest
}

last_segment : Str -> Str
last_segment = |path|
	match List.last(Str.split_on(path, "/")) {
		Ok(segment) => segment
		Err(_) => path
	}

lower : Str -> Str
lower = |text| Str.from_utf8_lossy(List.map(Str.to_utf8(text), |byte| if byte >= 'A' and byte <= 'Z' { byte + 32 } else { byte }))

## Keeps a `content-type` the app set; otherwise adds the file's.
with_content_type : List(Http.ResponseHeader), Str -> List(Http.ResponseHeader)
with_content_type = |headers, path|
	if List.any(headers, |header| lower(Http.HeaderName.inner(header.name)) == "content-type") {
		headers
	} else {
		with_header(headers, "content-type", FileReply.content_type(path))
	}

expect FileReply.content_type("index.html") == "text/html; charset=utf-8"
expect FileReply.content_type("app/main.JS") == "text/javascript; charset=utf-8"
expect FileReply.content_type("README") == "application/octet-stream"
expect FileReply.content_type(".config/settings") == "application/octet-stream"
expect FileReply.content_type("a.b/c") == "application/octet-stream"
expect relative("//a/b.txt") == "a/b.txt"

expect FileReply.http_date(784_111_777) == "Sun, 06 Nov 1994 08:49:37 GMT"
expect FileReply.http_date(0) == "Thu, 01 Jan 1970 00:00:00 GMT"
expect FileReply.http_date(951_782_400) == "Tue, 29 Feb 2000 00:00:00 GMT"
expect FileReply.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT") == Ok(784_111_777)
expect FileReply.parse_http_date("Tue, 29 Feb 2000 00:00:00 GMT") == Ok(951_782_400)
expect FileReply.parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT") == Err(Invalid)
expect FileReply.parse_http_date(FileReply.http_date(1_798_765_432)) == Ok(1_798_765_432)

expect FileReply.etag({ size: 255, modified_seconds: 16, directory: Bool.False }, "") == "W/\"ff-10\""
expect FileReply.etag({ size: 0, modified_seconds: 0, directory: Bool.False }, "br") == "W/\"0-0-br\""

expect {
	conditions = { if_none_match: Ok("\"x\", W/\"ff-10\""), if_modified_since: Err(Missing) }
	FileReply.not_modified(conditions, "W/\"ff-10\"", 16)
}
expect FileReply.not_modified({ if_none_match: Ok("*"), if_modified_since: Err(Missing) }, "W/\"a\"", 0)
# If-None-Match wins over If-Modified-Since.
expect !FileReply.not_modified({ if_none_match: Ok("\"other\""), if_modified_since: Ok("Sun, 06 Nov 1994 08:49:37 GMT") }, "W/\"a\"", 0)
expect FileReply.not_modified({ if_none_match: Err(Missing), if_modified_since: Ok("Sun, 06 Nov 1994 08:49:37 GMT") }, "W/\"a\"", 784_111_777)
expect !FileReply.not_modified({ if_none_match: Err(Missing), if_modified_since: Ok("Sun, 06 Nov 1994 08:49:37 GMT") }, "W/\"a\"", 784_111_778)
expect !FileReply.not_modified({ if_none_match: Err(Missing), if_modified_since: Ok("yesterday") }, "W/\"a\"", 0)

expect FileReply.range("bytes=0-9", 100) == Part({ start: 0, length: 10 })
expect FileReply.range("bytes=90-", 100) == Part({ start: 90, length: 10 })
expect FileReply.range("bytes=-10", 100) == Part({ start: 90, length: 10 })
expect FileReply.range("bytes=-500", 100) == Part({ start: 0, length: 100 })
expect FileReply.range("bytes=50-500", 100) == Part({ start: 50, length: 50 })
expect FileReply.range("bytes=100-", 100) == Unsatisfiable
expect FileReply.range("bytes=-0", 100) == Unsatisfiable
expect FileReply.range("bytes=0-1,5-6", 100) == Whole
expect FileReply.range("items=0-1", 100) == Whole
expect FileReply.range("bytes=9-1", 100) == Whole
expect FileReply.range("bytes=x-1", 100) == Whole

