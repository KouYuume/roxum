HostBody := [].{
	## The result of `Http.RequestStream.read!`.
	##
	## - `Chunk`: the next bytes of the body; never empty.
	## - `End`: the body has been read completely.
	## - `Closed`: the handle no longer refers to the current request, because
	##   its handler has returned or it came from an earlier request.
	## - `BadRequest`: the body framing is invalid or the connection ended
	##   before the body did.
	## - `TooLarge`: the body exceeds its limit (`Server.Limits` or a route's
	##   `BodyLimit` layer), or its chunked framing is out of proportion to
	##   its data.
	## - `TimedOut`: the request body timeout passed: for the whole body, or
	##   for a streamed read, while no bytes arrived.
	## - `Failed`: an internal error in the host.
	## - `InvalidLimit`: `maximum_bytes` was 0.
	##
	## On HTTP/1, after `BadRequest`, `TooLarge`, `TimedOut`, or `Failed`, the
	## host closes the connection once the response is sent. The standard
	## extractors map these to 400, 413, 408, and 500. HTTP/2 reads wait for
	## finite input EOF; route limits can return `TooLarge`, while transport
	## limits, timeouts, and resets cancel the request without returning to Roc.
	## Other HTTP/2 streams remain independent.
	RequestRead := [
		Chunk(List(U8)),
		End,
		Closed,
		BadRequest,
		TooLarge,
		TimedOut,
		Failed,
		InvalidLimit,
	]

	## Reads the next part of the body: as a body read whole into memory when
	## the last argument is true, otherwise as a stream.
	read! : U64, U64, Bool => HostBody.RequestRead
	## Sets the limit of the body read whole into memory, in bytes.
	limit_whole! : U64, U64 => {}
	## Sets the limit of the body read as a stream, in bytes; the largest
	## `U64` for none.
	limit_streamed! : U64, U64 => {}
}
