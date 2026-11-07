# Streaming lifecycle

The host owns sockets, deadlines, HTTP framing, and backpressure. Applications read inbound chunks with `Handler.streaming` and produce outbound chunks with `Reply.stream` or `Reply.stream_with`. Internal reader tokens are not public socket handles.

## Response lifecycle

Validate the entire response head before sending any bytes. The writer callback emits chunks under the response-write deadline; a blocked write yields the request fiber. Empty writes do not emit an HTTP terminal chunk. When the callback returns, HTTP/1.1 receives the terminal chunk and the connection follows its persistence policy.

Writer capabilities belong to the active request and callback. The host allocates a nonzero capability token when a stream starts; buffered responses do not allocate one. Token zero is invalid. Writes after closure or with an invalid token fail with `StreamClosed`. HEAD, 204, 205, and 304 responses do not transmit a body. A crash after the head has been sent closes the connection instead of sending a second status line.

For streams configured with `ends_on_drain`, draining stops the handler at an eligible wait and finishes the response. A configured keep-alive payload may be written while the callback waits. Disconnect cancellation releases the fiber's heap and external resources; execution does not continue after the cancelled wait.

## Connection cleanup

| Condition | Connection behavior |
|---|---|
| Request consumed, response completed | Apply HTTP persistence rules |
| Unread body fits entirely in the receive buffer | Invalidate reader, skip remaining framing, preserve the next request |
| Unread body requires another socket read | Close without draining the socket |
| Read framing failure, EOF, or timeout | Invalidate reader and close |
| Write timeout or peer disconnect | Close and cancel outstanding request work |
| Crash after response head | Close without a terminal chunk |

Skipping an unread body must not consume bytes from the next request. Production cleanup does not introduce another socket-read wait merely to preserve keep-alive.

Request allocations are reclaimed as values are released; a stream must not retain memory in proportion to all bytes already transmitted. Final request cleanup releases remaining allocations. See [execution and ownership](execution-model.md) and the [streaming guide](../guides/streaming.md).
