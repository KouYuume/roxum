import HostStream
import Http

## Writes a response body as it goes, for the function given to
## `Reply.stream`. The handle is opaque and valid only inside that function.
ResponseWriter :: U64.{
	## How a written body behaves while its function waits, for
	## `Reply.stream_with`. Fields left out keep their defaults. HTTP/2
	## currently supports only the default options.
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
	## does not take them; other requests go on meanwhile. On HTTP/1, returns
	## `Err(StreamClosed)` when the client is gone or a write exceeds
	## `Server.Timeouts.response_write_milliseconds`; later writes fail too.
	## On HTTP/2, that timeout covers the whole response, and cancellation
	## abandons the request: code after a blocked write does not resume.
	## Empty bytes write nothing. For a `HEAD`
	## request and for 204 and 304 responses the bytes are not sent.
	write! : ResponseWriter, List(U8) => Try({}, [StreamClosed])
	write! = |ResponseWriter.(token), bytes|
		if HostStream.write!(token, bytes) {
			Ok({})
		} else {
			Err(StreamClosed)
		}

	## Offers at most 16 KiB without waiting. Pending retains no bytes; retry
	## after writable readiness, or process input meanwhile. Accepted transfers
	## ownership into bounded output storage, not acknowledgement by the peer.
	## Oversized writes fail even under backpressure. HTTP/1 is unavailable.
	try_write! : ResponseWriter, List(U8) => Try([Accepted, Pending], [Unavailable, InvalidState, TooLarge, StreamClosed])
	try_write! = |ResponseWriter.(token), bytes|
		match HostStream.try_write!(token, bytes) {
			0 => Ok(Accepted)
			1 => Err(Unavailable)
			2 => Ok(Pending)
			3 => Err(StreamClosed)
			5 => Err(TooLarge)
			_ => Err(InvalidState)
		}

	## Platform coordination only: the body capability is never exposed to apps.
	wait! : ResponseWriter, Http.RequestStream, U8 => U8
	wait! = |ResponseWriter.(token), stream, interest| stream.wait!(token, interest)

	## Completes HTTP/2 output with trailers, after accepted DATA. Waits until
	## the terminal frame is written to the socket; this is not peer receipt.
	## A successful finish closes this writer. Repeated finish or later writes
	## fail. Invalid trailers leave completion available for retry. HTTP/1 is
	## unavailable. Cancellation stops the request without returning.
	## Complete required application I/O before finish. Immediate result handling
	## can run after success, but further waits can be cancelled by normal stream
	## closure; finish does not extend the request's execution lifetime.
	finish! : ResponseWriter, List(Http.ResponseHeader) => Try({}, [Unavailable, InvalidState, InvalidTrailers, StreamClosed])
	finish! = |ResponseWriter.(token), trailers|
		match HostStream.finish!(token, trailers) {
			0 => Ok({})
			1 => Err(Unavailable)
			2 => Err(InvalidTrailers)
			3 => Err(StreamClosed)
			_ => Err(InvalidState)
		}

	## The writer for a token from `HostStream.start!`. Platform code only.
	from_token = |token| ResponseWriter.(token)
}
