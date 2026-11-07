import pf.Instant
import pf.Log
import pf.Method
import pf.Middleware
import pf.Reply

Trace := [].{
	## Writes one Info log line per request with the method, path, status,
	## duration, and the request's ID, which the host's logs use too. The
	## duration runs from when the platform started handling the request
	## (`RequestHead.received_at`) to when the reply passes this layer. A
	## function of `{}` because a value cannot be generic over `model`.
	layer : {} -> List(Middleware.Stage(model, tag, provided))
	layer = |{}| [
		Middleware.Stage.AfterHandler(
			|_model, head, reply| {
				finished = Instant.now!({})
				Log.info!(
					Trace.line(
						{
							method: head.method,
							path: head.path,
							status: Reply.status_code(reply),
							duration_nanoseconds: Instant.nanoseconds_between(head.received_at, finished),
							request_id: head.request_id,
						},
					),
				)
				reply
			},
		),
	]

	line :
		{
			method : Method,
			path : Str,
			status : U16,
			duration_nanoseconds : U64,
			request_id : Str,
		}
		-> Str
	line = |entry|
		"${Method.to_str(entry.method)} ${escape_field(entry.path)} ${entry.status.to_str()} ${milliseconds(entry.duration_nanoseconds)} request_id=${escape_field(entry.request_id)}"
}

# Formats nanoseconds as milliseconds with microsecond precision, truncating.
milliseconds : U64 -> Str
milliseconds = |nanoseconds| {
	microseconds = nanoseconds // 1_000
	fraction = (microseconds % 1_000).to_str()
	padding = Str.repeat("0", 3 - Str.count_utf8_bytes(fraction))
	"${(microseconds // 1_000).to_str()}.${padding}${fraction}ms"
}

# A request path and ID are validated before they reach Roc, but middleware
# may rewrite the path, and a request built in Roc code is not validated.
# Percent-encode spaces and control bytes so one request stays on one log line
# with space-separated fields.
escape_field : Str -> Str
escape_field = |field| {
	var $escaped = []
	for byte in field.to_utf8() {
		if byte <= 0x20 or byte == 0x7F {
			$escaped = List.concat($escaped, ['%', hex_digit(byte // 16), hex_digit(byte % 16)])
		} else {
			$escaped = List.append($escaped, byte)
		}
	}
	Str.from_utf8_lossy($escaped)
}

hex_digit : U8 -> U8
hex_digit = |nibble| if nibble < 10 { '0' + nibble } else { 'A' + nibble - 10 }

# Duration boundaries around one microsecond and one millisecond.
expect milliseconds(0) == "0.000ms"
expect milliseconds(999) == "0.000ms"
expect milliseconds(1_000) == "0.001ms"
expect milliseconds(999_999) == "0.999ms"
expect milliseconds(1_000_000) == "1.000ms"
expect milliseconds(1_250_000) == "1.250ms"
expect milliseconds(12_345_678_000) == "12345.678ms"

# Escape boundaries: 0x20 and 0x7F are encoded; 0x21 and 0x7E are kept.
expect escape_field("/a b") == "/a%20b"
expect escape_field("/a!b~") == "/a!b~"
expect escape_field("/\u(0)\n\u(1F)") == "/%00%0A%1F"
expect escape_field("/\u(7F)") == "/%7F"
expect escape_field("/users/%FF") == "/users/%FF"
expect escape_field("/鵬") == "/鵬"

expect {
	entry = {
		method: GET,
		path: "/users/1",
		status: 200,
		duration_nanoseconds: 1_250_000,
		request_id: "abc",
	}
	Trace.line(entry) == "GET /users/1 200 1.250ms request_id=abc"
}

expect {
	entry = {
		method: HEAD,
		path: "/",
		status: 404,
		duration_nanoseconds: 0,
		request_id: "a b",
	}
	Trace.line(entry) == "HEAD / 404 0.000ms request_id=a%20b"
}
