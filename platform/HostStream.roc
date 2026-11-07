import Http

HostStream := [].{
	## Sends the head of a streamed response (its status and headers; the
	## body is ignored) and returns the stream's token, or 0 when it did not
	## start: past `Server.Limits.maximum_streams` the host has answered 503,
	## or the client is gone. While the body is quiet for
	## `keep_alive_milliseconds` (0 for never), the host writes
	## `keep_alive_bytes`. With `ends_on_drain`, a drain ends the body at the
	## function's next wait. The last argument is the body's length, sent as
	## `Content-Length`, or the largest `U64` when it is not known. With the
	## last argument, the host gzip-compresses the body as it goes; its head
	## says so already.
	start! : Http.Response, U64, List(U8), Bool, U64, Bool => U64
	## Writes the next part of the body; false when the stream is over.
	write! : U64, List(U8) => Bool
}
