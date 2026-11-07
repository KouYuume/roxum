import ResponseWriter

## The writer of a JSON Lines body (`Reply.json_lines`).
JsonLines :: ResponseWriter.{
	## Sends `value` encoded as JSON, and the newline after it. JSON escapes
	## newlines inside strings, so one value stays on one line.
	write! : JsonLines, a => Try({}, [StreamClosed]) where [a.Json.Encodable([])]
	write! = |JsonLines.(writer), value| ResponseWriter.write!(writer, "${Json.to_str(value)}\n".to_utf8())

	## For `Reply.json_lines`.
	from_writer : ResponseWriter -> JsonLines
	from_writer = |writer| JsonLines.(writer)
}
