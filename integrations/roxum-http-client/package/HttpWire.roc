## HTTP/1.1 client messages: checking and writing a request head, and
## reading a response from the bytes received so far. No I/O.
HttpWire := [].{

	## A response read off the connection. `reusable` says the connection
	## may carry another request: the response ended where its framing said,
	## nothing followed it, and neither side asked to close.
	Message : {
		status : U16,
		headers : List((Str, Str)),
		body : List(U8),
		reusable : Bool,
	}

	Head : {
		status : U16,
		headers : List((Str, Str)),
		keep_alive : Bool,
	}

	## Where a body ends: after a length, in chunks, or when the server
	## closes the connection.
	Stage : [
		ReadingHead,
		ReadingLength(HttpWire.Head, U64, U64),
		ReadingChunks(HttpWire.Head, HttpWire.Chunks),
		ReadingToEnd(HttpWire.Head, U64),
	]

	## Chunked decoding so far: where the next chunk-size line or trailer
	## line starts in the buffer, and the data decoded before it.
	Chunks : { offset : U64, body : List(U8), in_trailers : Bool }

	## The bytes received for one response and how far they have been read.
	Reader : {
		buffer : List(U8),
		head_request : Bool,
		maximum_body_bytes : U64,
		scanned : U64,
		stage : HttpWire.Stage,
	}

	## The checks a request gets before any byte is sent: the method is a
	## token; header names are tokens, values have no control characters
	## but tab, and the client's own framing headers are not set by hand.
	check_method : Str -> Try({}, [HttpClientInvalidMethod])
	check_method = |method|
		if method != "" and method.to_utf8().all(token_byte) {
			Ok({})
		} else {
			Err(HttpClientInvalidMethod)
		}

	check_header : Str, Str -> Try({}, [HttpClientInvalidHeader(Str)])
	check_header = |name, value| {
		valid_name = name != "" and name.to_utf8().all(token_byte)
		reserved = ["host", "content-length", "transfer-encoding"].any(|reserved_name| name.caseless_ascii_equals(reserved_name))
		if valid_name and !reserved and value.to_utf8().all(value_byte) {
			Ok({})
		} else if valid_name {
			Err(HttpClientInvalidHeader(name))
		} else {
			Err(HttpClientInvalidHeader("an invalid header name"))
		}
	}

	## The request line and headers, without the empty line that ends the
	## head, so that headers the host writes can follow. `Content-Length` is
	## sent when there is a body or the method usually has one.
	request_head : { method : Str, target : Str, authority : Str, headers : List((Str, Str)), body_length : U64 } -> List(U8)
	request_head = |{ method, target, authority, headers, body_length }| {
		var $head = "${method} ${target} HTTP/1.1\r\nHost: ${authority}\r\n"
		for (name, value) in headers {
			$head = "${$head}${name}: ${value}\r\n"
		}
		with_length = if body_length > 0 or method == "POST" or method == "PUT" or method == "PATCH" {
			"${$head}Content-Length: ${body_length.to_str()}\r\n"
		} else {
			$head
		}
		with_length.to_utf8()
	}

	## A reader for the response to a request; `head_request` because the
	## response to `HEAD` has no body whatever its headers say.
	reader : Bool, U64 -> HttpWire.Reader
	reader = |head_request, maximum_body_bytes| { buffer: [], head_request, maximum_body_bytes, scanned: 0, stage: ReadingHead }

	## Adds received bytes and reads as far as they go. `ended` says the
	## server closed the connection, which ends a body without a length.
	## Interim responses (1xx) are skipped.
	advance : HttpWire.Reader, List(U8), Bool -> [Done(HttpWire.Message), NeedMore(HttpWire.Reader), EndedEarly, TooLarge, Invalid(Str)]
	advance = |reader_before, received, ended| {
		# Bound framing as well as decoded bytes. Eight wire bytes per body
		# byte permits one-byte chunks; 64 KiB covers headers and trailers.
		maximum = 18_446_744_073_709_551_615
		wire_limit = if reader_before.maximum_body_bytes > (maximum - maximum_head_bytes) // 8 {
			maximum
		} else {
			reader_before.maximum_body_bytes * 8 + maximum_head_bytes
		}
		if received.len() > wire_limit - reader_before.buffer.len() {
			return TooLarge
		}
		var $reader = { ..reader_before, buffer: reader_before.buffer.concat(received) }
		while Bool.True {
			current = $reader
			match current.stage {
				ReadingHead =>
					match find_head_end(current.buffer, current.scanned) {
						Found(end) => {
							if end > maximum_head_bytes {
								return Invalid("the response head is larger than 64 KiB")
							}
							head = match parse_head(current.buffer.take_first(end)) {
								Ok(parsed) => parsed
								Err(Invalid(problem)) => return Invalid(problem)
							}
							if head.status >= 100 and head.status < 200 {
								if head.status == 101 {
									return Invalid("the server switched protocols")
								}
								$reader = { ..current, buffer: current.buffer.drop_first(end), scanned: 0 }
							} else {
								stage = match body_stage(head, end, current.head_request) {
									Ok(next) => next
									Err(Invalid(problem)) => return Invalid(problem)
								}
								$reader = { ..current, stage }
							}
						}
						Missing(scanned) => {
							if current.buffer.len() > maximum_head_bytes {
								return Invalid("the response head is larger than 64 KiB")
							}
							return if ended {
								EndedEarly
							} else {
								NeedMore({ ..current, scanned })
							}
						}
					}
				ReadingLength(head, start, length) => {
					if length > current.maximum_body_bytes {
						return TooLarge
					}
					end = start + length
					return if current.buffer.len() >= end {
						Done({ status: head.status, headers: head.headers, body: current.buffer.sublist({ start, len: length }), reusable: head.keep_alive and current.buffer.len() == end })
					} else if ended {
						EndedEarly
					} else {
						NeedMore(current)
					}
				}
				ReadingToEnd(head, start) => {
					if current.buffer.len() - start > current.maximum_body_bytes {
						return TooLarge
					}
					return if ended {
						Done({ status: head.status, headers: head.headers, body: current.buffer.drop_first(start), reusable: Bool.False })
					} else {
						NeedMore(current)
					}
				}
				ReadingChunks(head, chunks) =>
					return match read_chunks(current.buffer, chunks, current.maximum_body_bytes) {
						Finished(body, end) => Done({ status: head.status, headers: head.headers, body, reusable: head.keep_alive and current.buffer.len() == end })
						Partial(progress) => if ended {
							EndedEarly
						} else {
							NeedMore({ ..current, stage: ReadingChunks(head, progress) })
						}
						ChunksTooLarge => TooLarge
						Malformed(problem) => Invalid(problem)
					}
			}
		}
	}

	## The value of the first header named `name`, ignoring case.
	header : List((Str, Str)), Str -> Try(Str, [NotFound])
	header = |headers, name|
		match headers.find_first(|(key, _)| key.caseless_ascii_equals(name)) {
			Ok((_, value)) => Ok(value)
			Err(_) => Err(NotFound)
		}

	## True when a `Connection` header lists `close`.
	asks_to_close : List((Str, Str)) -> Bool
	asks_to_close = |headers|
		headers.any(|(name, value)| name.caseless_ascii_equals("connection") and value.split_on(",").any(|option| option.trim().caseless_ascii_equals("close")))
}

maximum_head_bytes : U64
maximum_head_bytes = 65_536

## `!#$%&'*+-.^_`|~`, digits, and letters (RFC 9110 `tchar`).
token_byte : U8 -> Bool
token_byte = |byte|
	(byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or "!#$%&'*+-.^_`|~".to_utf8().contains(byte)

## Visible characters, space, tab, and bytes of UTF-8 text.
value_byte : U8 -> Bool
value_byte = |byte| byte == '\t' or (byte >= 32 and byte != 127)

## The end of the head (just past the empty line), or how far the search
## got. Lines may end in CRLF or a bare LF.
find_head_end : List(U8), U64 -> [Found(U64), Missing(U64)]
find_head_end = |buffer, scanned| {
	var $index = scanned
	while $index < buffer.len() {
		if buffer.get($index) == Ok('\n') {
			next = buffer.get($index + 1)
			if next == Ok('\n') {
				return Found($index + 2)
			}
			if next == Ok('\r') and buffer.get($index + 2) == Ok('\n') {
				return Found($index + 3)
			}
			if next.is_err() or (next == Ok('\r') and buffer.get($index + 2).is_err()) {
				# Wait for the bytes that decide it.
				return Missing($index)
			}
		}
		$index = $index + 1
	}
	Missing($index)
}

parse_head : List(U8) -> Try(HttpWire.Head, [Invalid(Str)])
parse_head = |bytes| {
	lines = bytes.split_on('\n').map(
		|line| if line.last() == Ok('\r') {
			line.drop_last(1)
		} else {
			line
		},
	).drop_if(List.is_empty)
	status_line = Str.from_utf8(lines.first() ?? []) ?? return Err(Invalid("the status line is not text"))
	(version, status) = match status_line.split_on(" ") {
		[version_text, code, ..] => (version_text, U16.from_str(code) ?? 0)
		_ => ("", 0)
	}
	if (version != "HTTP/1.1" and version != "HTTP/1.0") or status < 100 or status > 999 {
		return Err(Invalid("the status line is not HTTP/1.x"))
	}
	var $headers = []
	for line in lines.drop_first(1) {
		if line.first() == Ok(' ') or line.first() == Ok('\t') {
			return Err(Invalid("a folded header line"))
		}
		{ before, after } = line.split_first(':') ?? return Err(Invalid("a header line without a colon"))
		if before.is_empty() or !before.all(token_byte) or !after.all(value_byte) {
			return Err(Invalid("a header with an invalid name or value"))
		}
		name = Str.from_utf8(before) ?? return Err(Invalid("a header name is not text"))
		value = Str.from_utf8(after) ?? return Err(Invalid("a header value is not UTF-8"))
		$headers = $headers.append((name, value.trim()))
	}
	headers = $headers
	keep_alive = version == "HTTP/1.1" and !HttpWire.asks_to_close(headers)
	Ok({ status, headers, keep_alive })
}

## How the body after a head that ends at `end` is framed (RFC 9112 §6.3).
body_stage : HttpWire.Head, U64, Bool -> Try(HttpWire.Stage, [Invalid(Str)])
body_stage = |head, end, head_request| {
	if head_request or head.status == 204 or head.status == 304 {
		return Ok(ReadingLength(head, end, 0))
	}
	var $has_encoding = Bool.False
	var $last_encoding = ""
	for (name, value) in head.headers {
		if name.caseless_ascii_equals("transfer-encoding") {
			$has_encoding = Bool.True
			$last_encoding = value
		}
	}
	if $has_encoding {
		# Joining repeated fields cannot change the final token of the last
		# field, including an empty token. Avoid materializing earlier fields.
		last = ($last_encoding.split_on(",").last() ?? "").trim()
		lengths_too = HttpWire.header(head.headers, "content-length").is_ok()
		next_head = { ..head, keep_alive: head.keep_alive and !lengths_too }
		return if last.caseless_ascii_equals("chunked") {
			Ok(ReadingChunks(next_head, { offset: end, body: [], in_trailers: Bool.False }))
		} else {
			Ok(ReadingToEnd(head, end))
		}
	}
	var $first = ""
	var $count = 0.U64
	for (name, value) in head.headers {
		if name.caseless_ascii_equals("content-length") {
			for part in value.split_on(",") {
				trimmed = part.trim()
				if $count == 0 { $first = trimmed }
				else if trimmed != $first { return Err(Invalid("an invalid Content-Length")) }
				$count = $count + 1
			}
		}
	}
	first = $first
	# Preserve the existing treatment of no value or one empty value.
	if $count == 0 or ($count == 1 and first.is_empty()) {
		return Ok(ReadingToEnd(head, end))
	}
	if first.is_empty() or !first.to_utf8().all(|byte| byte >= '0' and byte <= '9') {
		return Err(Invalid("an invalid Content-Length"))
	}
	length = U64.from_str(first) ?? return Err(Invalid("an invalid Content-Length"))
	Ok(ReadingLength(head, end, length))
}

## Decodes chunks from `progress` as far as the buffer goes.
read_chunks : List(U8), HttpWire.Chunks, U64 -> [Finished(List(U8), U64), Partial(HttpWire.Chunks), ChunksTooLarge, Malformed(Str)]
read_chunks = |buffer, progress, maximum_body_bytes| {
	var $progress = progress
	while Bool.True {
		current = $progress
		line_end = match line_end_from(buffer, current.offset) {
			Ok(found) => found
			Err(NeedMore) => {
				if buffer.len() - current.offset > maximum_head_bytes {
					return Malformed("a chunk line exceeds 64 KiB")
				}
				return Partial(current)
			}
		}
		if line_end.next - current.offset > maximum_head_bytes {
			return Malformed("a chunk line exceeds 64 KiB")
		}
		line = buffer.sublist({ start: current.offset, len: line_end.content - current.offset })
		if current.in_trailers {
			if line.is_empty() {
				return Finished(current.body, line_end.next)
			}
			$progress = { ..current, offset: line_end.next }
		} else {
			size_text = line.split_first(';').map_ok(|parts| parts.before) ?? line
			size = hex_size(size_text) ?? return Malformed("an invalid chunk size")
			if size == 0 {
				$progress = { ..current, offset: line_end.next, in_trailers: Bool.True }
			} else {
				if current.body.len() + size > maximum_body_bytes {
					return ChunksTooLarge
				}
				data_end = line_end.next + size
				if buffer.len() < data_end + 2 {
					return Partial(current)
				}
				after_data = buffer.sublist({ start: data_end, len: 2 })
				next = if after_data == ['\r', '\n'] {
					data_end + 2
				} else if after_data.first() == Ok('\n') {
					data_end + 1
				} else {
					return Malformed("a chunk without its line end")
				}
				$progress = { offset: next, body: current.body.concat(buffer.sublist({ start: line_end.next, len: size })), in_trailers: Bool.False }
			}
		}
	}
}

## Where the line starting at `start` ends: the end of its content and the
## start of the next line.
line_end_from : List(U8), U64 -> Try({ content : U64, next : U64 }, [NeedMore])
line_end_from = |buffer, start| {
	newline = buffer.drop_first(start).find_first_index(|byte| byte == '\n') ?? return Err(NeedMore)
	at = start + newline
	content = if at > start and buffer.get(at - 1) == Ok('\r') {
		at - 1
	} else {
		at
	}
	Ok({ content, next: at + 1 })
}

## Hexadecimal digits, with spaces or tabs after them; at most 15 digits.
hex_size : List(U8) -> Try(U64, [Invalid])
hex_size = |bytes| {
	digits = bytes.drop_if(|byte| byte == ' ' or byte == '\t')
	if digits.is_empty() or digits.len() > 15 or bytes.take_first(digits.len()) != digits {
		return Err(Invalid)
	}
	var $size = 0
	for byte in digits {
		value = if byte >= '0' and byte <= '9' {
			(byte - '0').to_u64()
		} else if byte >= 'a' and byte <= 'f' {
			(byte - 'a').to_u64() + 10
		} else if byte >= 'A' and byte <= 'F' {
			(byte - 'A').to_u64() + 10
		} else {
			return Err(Invalid)
		}
		$size = $size * 16 + value
	}
	Ok($size)
}

## Feeds `parts` one after another, then the end of the connection when
## `ended`, and returns the final outcome.
feed_all : HttpWire.Reader, List(List(U8)), Bool -> [Done(HttpWire.Message), NeedMore(HttpWire.Reader), EndedEarly, TooLarge, Invalid(Str)]
feed_all = |start, parts, ended| {
	var $reader = start
	var $index = 0
	while $index < parts.len() {
		part = parts.get($index) ?? []
		last = $index + 1 == parts.len()
		match HttpWire.advance($reader, part, last and ended) {
			NeedMore(next) => {
				$reader = next
			}
			other => return other
		}
		$index = $index + 1
	}
	if parts.is_empty() {
		HttpWire.advance($reader, [], ended)
	} else {
		NeedMore($reader)
	}
}

bytes_of : Str -> List(U8)
bytes_of = |text| text.to_utf8()

body_of = |outcome|
	match outcome {
		Done(message) => Ok((message.status, Str.from_utf8_lossy(message.body), message.reusable))
		_ => Err(outcome)
	}

# Request heads.
expect HttpWire.request_head({ method: "GET", target: "/v1?x=1", authority: "example.com", headers: [("Accept", "application/json")], body_length: 0 }) == bytes_of("GET /v1?x=1 HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n")
expect HttpWire.request_head({ method: "POST", target: "/", authority: "example.com:8080", headers: [], body_length: 0 }) == bytes_of("POST / HTTP/1.1\r\nHost: example.com:8080\r\nContent-Length: 0\r\n")
expect HttpWire.request_head({ method: "DELETE", target: "/x", authority: "h", headers: [], body_length: 3 }) == bytes_of("DELETE /x HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n")
expect HttpWire.check_header("X-Trace", "a\tb") == Ok({})
expect HttpWire.check_header("X-Trace", "a\r\nInjected: 1") == Err(HttpClientInvalidHeader("X-Trace"))
expect HttpWire.check_header("Bad Name", "x") == Err(HttpClientInvalidHeader("an invalid header name"))
expect HttpWire.check_header("content-length", "5") == Err(HttpClientInvalidHeader("content-length"))
expect HttpWire.check_header("Host", "other") == Err(HttpClientInvalidHeader("Host"))
expect HttpWire.check_method("PROPFIND") == Ok({})
expect HttpWire.check_method("GET /") == Err(HttpClientInvalidMethod)

# Content-Length: one short, exactly, and with bytes after it.
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")], Bool.False)) == Ok((200, "hello", Bool.True))
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello!")], Bool.False)) == Ok((200, "hello", Bool.False))
expect
	match feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell")], Bool.False) {
		NeedMore(_) => Bool.True
		_ => Bool.False
	}
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell")], Bool.True) == EndedEarly

# Received a byte at a time, the head split between CR and LF.
expect {
	text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
	parts = text.to_utf8().map(|byte| [byte])
	body_of(feed_all(HttpWire.reader(Bool.False, 100), parts, Bool.False)) == Ok((200, "ok", Bool.True))
}

# The body limit: just under, at, and just over.
expect body_of(feed_all(HttpWire.reader(Bool.False, 4), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc")], Bool.False)) == Ok((200, "abc", Bool.True))
expect body_of(feed_all(HttpWire.reader(Bool.False, 4), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd")], Bool.False)) == Ok((200, "abcd", Bool.True))
expect feed_all(HttpWire.reader(Bool.False, 4), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")], Bool.False) == TooLarge
expect feed_all(HttpWire.reader(Bool.False, 4), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")], Bool.False) == TooLarge
expect feed_all(HttpWire.reader(Bool.False, 4), [bytes_of("HTTP/1.1 200 OK\r\n\r\nabcde")], Bool.True) == TooLarge

# Chunked: extensions, trailers, split delivery, and broken sizes.
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;name=x\r\nhi\r\n3\r\n!!!\r\n0\r\nX-Trailer: t\r\n\r\n")], Bool.False)) == Ok((200, "hi!!!", Bool.True))
expect {
	text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n"
	parts = text.to_utf8().map(|byte| [byte])
	body_of(feed_all(HttpWire.reader(Bool.False, 100), parts, Bool.False)) == Ok((200, "hi", Bool.True))
}
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhi\r\n0\r\n\r\n")], Bool.False) == Invalid("an invalid chunk size")
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhiXX0\r\n\r\n")], Bool.False) == Invalid("a chunk without its line end")
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n")], Bool.True) == EndedEarly
expect feed_all(HttpWire.reader(Bool.False, 1_000_000_000), [bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1000000000000000\r\n")], Bool.False) == Invalid("an invalid chunk size")

# Until the connection ends; 204, 304, and HEAD without a body.
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\n\r\nall of it")], Bool.True)) == Ok((200, "all of it", Bool.False))
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 204 No Content\r\n\r\n")], Bool.False)) == Ok((204, "", Bool.True))
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n")], Bool.False)) == Ok((304, "", Bool.True))
expect body_of(feed_all(HttpWire.reader(Bool.True, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n")], Bool.False)) == Ok((200, "", Bool.True))

# Interim responses are skipped; a 101 is refused.
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 1\r\n\r\nx")], Bool.False)) == Ok((201, "x", Bool.True))
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 101 Switching Protocols\r\n\r\n")], Bool.False) == Invalid("the server switched protocols")

# Keep-alive: `Connection: close`, HTTP/1.0, and both framings at once.
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nConnection: keep-alive, Close\r\nContent-Length: 1\r\n\r\nx")], Bool.False)) == Ok((200, "x", Bool.False))
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\nx")], Bool.False)) == Ok((200, "x", Bool.False))
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n")], Bool.False)) == Ok((200, "x", Bool.False))

# Broken heads.
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/2 200 OK\r\n\r\n")], Bool.False) == Invalid("the status line is not HTTP/1.x")
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nContent-Length: 1, 2\r\n\r\nx")], Bool.False) == Invalid("an invalid Content-Length")
expect feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\r\nX: a\r\n b\r\n\r\n")], Bool.False) == Invalid("a folded header line")
expect feed_all(HttpWire.reader(Bool.False, 100), [], Bool.True) == EndedEarly
expect body_of(feed_all(HttpWire.reader(Bool.False, 100), [bytes_of("HTTP/1.1 200 OK\nContent-Length: 1\n\nx")], Bool.False)) == Ok((200, "x", Bool.True))
expect HttpWire.header([("Content-Type", "text/plain")], "content-type") == Ok("text/plain")

# Completed and fragmented heads share the same inclusive 64 KiB boundary.
expect {
	prefix = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX: ".to_utf8()
	List.all(
		[65_535, 65_536, 65_537],
		|size| {
			wire = prefix.concat(List.repeat('a', size - prefix.len() - 4)).concat("\r\n\r\n".to_utf8())
			result = HttpWire.advance(HttpWire.reader(Bool.False, 1), wire, Bool.False)
			match result {
				Done(_) => size <= 65_536
				Invalid(_) => size > 65_536
				_ => Bool.False
			}
		},
	)
}
# Framing cannot consume an unbounded buffer when the decoded body is empty.
expect {
	head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: ".to_utf8()
	wire = head.concat(List.repeat('a', 131_072))
	HttpWire.advance(HttpWire.reader(Bool.False, 1), wire, Bool.False) == TooLarge
}

# The same head limit applies when its terminator arrives separately.
expect {
	prefix = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX: ".to_utf8()
	List.all(
		[65_535, 65_536, 65_537],
		|size| {
			before = prefix.concat(List.repeat('a', size - prefix.len() - 4))
			match HttpWire.advance(HttpWire.reader(Bool.False, 1), before, Bool.False) {
				NeedMore(reader) => match HttpWire.advance(reader, "\r\n\r\n".to_utf8(), Bool.False) {
					Done(_) => size <= 65_536
					Invalid(_) => size > 65_536
					_ => Bool.False
				}
				_ => Bool.False
			}
		},
	)
}
# For an empty body, the wire budget is exactly 64 KiB.
expect {
	head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: ".to_utf8()
	List.all(
		[65_535, 65_536, 65_537],
		|size| {
			wire = head.concat(List.repeat('a', size - head.len()))
			match HttpWire.advance(HttpWire.reader(Bool.False, 0), wire, Bool.False) {
				NeedMore(_) => size <= 65_536
				TooLarge => size > 65_536
				_ => Bool.False
			}
		},
	)
}

# Repeated Transfer-Encoding fields are ordered. Only the final token of
# the final field chooses chunked framing; an empty final token is retained.
expect List.all(
	[("gzip", "chunked", Bool.True), ("chunked", "gzip", Bool.False), ("chunked", "", Bool.False), ("gzip", " gzip, CHUNKED ", Bool.True), ("chunked", "chunked,", Bool.False)],
	|(first, last, chunked)| {
		head = { status: 200, headers: [("Transfer-Encoding", first), ("transfer-encoding", last)], keep_alive: Bool.True }
		match body_stage(head, 0, Bool.False) {
			Ok(ReadingChunks(_, _)) => chunked
			Ok(ReadingToEnd(_, _)) => !chunked
			_ => Bool.False
		}
	},
)

# Content-Length before or after Transfer-Encoding disables chunked reuse.
expect List.all(
	[[("Content-Length", "0"), ("Transfer-Encoding", "chunked")], [("Transfer-Encoding", "chunked"), ("Content-Length", "0")]],
	|headers| match body_stage({ status: 200, headers, keep_alive: Bool.True }, 0, Bool.False) {
		Ok(ReadingChunks(head, _)) => !head.keep_alive
		_ => Bool.False
	},
)

# Absent/single-empty/multiple-empty, duplicate agreement, decimal spelling,
# and the U64 upper boundary define the existing Content-Length contract.
expect List.all(
	[
		([], UntilEnd), ([""], UntilEnd), (["  "], UntilEnd), (["", ""], Bad),
		(["0"], Length(0.U64)), (["1"], Length(1.U64)),
		(["1", "1"], Length(1.U64)), (["1, 1"], Length(1.U64)),
		(["1", "2"], Bad), (["1", "01"], Bad), (["1,"], Bad), ([",1"], Bad),
		(["-1"], Bad), (["+1"], Bad), (["x"], Bad),
		(["18446744073709551614"], Length(18_446_744_073_709_551_614.U64)),
		(["18446744073709551615"], Length(18_446_744_073_709_551_615.U64)),
		(["18446744073709551616"], Bad),
	],
	|(values, expected)| {
		head = { status: 200, headers: values.map(|value| ("Content-Length", value)), keep_alive: Bool.True }
		actual = match body_stage(head, 0, Bool.False) {
			Ok(ReadingToEnd(_, _)) => UntilEnd
			Ok(ReadingLength(_, _, length)) => Length(length)
			_ => Bad
		}
		actual == expected
	},
)
