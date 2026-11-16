# Request representation

HTTP input is byte-oriented. Preserve data losslessly until an API explicitly asks for text, and reject invalid protocol structure at the boundary. Parsing and decoding are separate operations: routing should not silently reinterpret an encoded path as a different sequence of segments.

The host parses and validates HTTP framing and creates the host-facing `Http` request. The Roc pipeline constructs the public request context, performs route matching and extraction, and applies middleware. `RequestHead` is available before the body is read; buffered handlers receive body bytes through their route context. Streaming handlers receive chunks through `Handler.streaming`.

`RemoteAddr` distinguishes `Tcp({ ip, port })` from `Unix`. Unix peers have no IP identity; no loopback address or client pathname is synthesized. An integration must explicitly opt into trusting Unix forwarding headers, based on access to the socket directory.

Headers must pass wire validation before transmission. `HeaderValue` rejects CR/LF injection. `Status` literals accept 200 through 599. `PathSegment` percent-encodes interpolated data and rejects empty, `.` and `..` segments; `QueryValue` encodes query values. Runtime constructors report errors instead of trusting unvalidated strings.

Body limits belong to the server and route policy. Buffered and streaming handlers have different default limits; see [extractors](../guides/extractors.md) and [streaming](../guides/streaming.md). Framing failures and read timeouts must close the connection when the next request boundary cannot be recovered safely.

See [HTTP field lists](http-field-lists.md) for Connection and Expect parsing, and [streaming lifecycle](streaming.md) for unread-body handling.
