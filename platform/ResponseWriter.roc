import HostStream

## Writes a response body as it goes, for the function given to
## `Reply.stream`. The handle is opaque and valid only inside that function.
ResponseWriter :: U64.{
	## How a written body behaves while its function waits, for
	## `Reply.stream_with`. Fields left out keep their defaults.
	##
	## `ends_on_drain: Bool.True` lets the server end the body when it stops
	##: once a drain starts, the function stops at its next wait, as
	## if the code after it never ran, and the body ends cleanly. For a body
	## with no end, such as server-sent events, whose client connects again
	## to another worker. Without it, a drain waits for the body to end.
	Options := {
		keep_alive : ResponseWriter.KeepAlive ?? ResponseWriter.KeepAlive.None,
		ends_on_drain : Bool ?? Bool.False,
	}

	## Bytes the host writes when the body has been quiet for a while:
	## `Every({ milliseconds, bytes })` writes `bytes` each time `milliseconds`
	## pass without a write, while the function waits for anything. They go
	## out as a part of the body, never inside another; proxies that close
	## quiet connections then keep this one. `None` writes nothing.
	KeepAlive := [None, Every({ milliseconds : U64, bytes : List(U8) })]

	## Sends `bytes` as the next part of the body, waiting while the client
	## does not take them; other requests go on meanwhile. Returns
	## `Err(StreamClosed)` when the client is gone or did not take the bytes
	## within `Server.Timeouts.response_write_milliseconds`; the stream is then
	## over and later writes fail too. Empty bytes write nothing. For a `HEAD`
	## request and for 204 and 304 responses the bytes are not sent.
	write! : ResponseWriter, List(U8) => Try({}, [StreamClosed])
	write! = |ResponseWriter.(token), bytes|
		if HostStream.write!(token, bytes) {
			Ok({})
		} else {
			Err(StreamClosed)
		}

	## The writer for a token from `HostStream.start!`. Platform code only.
	from_token = |token| ResponseWriter.(token)
}
