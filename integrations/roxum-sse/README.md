# roxum-sse

`roxum-sse` is the first platform-dependent roxum integration package. It converts validated SSE events into
roxum's existing response-stream capability and adds the required response headers. It adds no hosted effect and
does not own sockets, backpressure, timeouts, or disconnect cleanup.

```roc
import sse.Sse

events = |_context|
	Ok(Sse.reply(|sse| {
		Sse.send!(sse, Sse.event("first"))?
		Sleep.millis!(1_000)
		Sse.send!(sse, Sse.event("second\nline") |> Sse.with_retry(1000))
	}))
```

`Sse.reply` sends a keep-alive comment (`:`) every 15 seconds without an event, and ends the stream when the server
stops, so the client connects again to another worker. `Sse.reply_with(Sse.Options.{ ... }, ...)` changes either, and
can send a `retry` field first. `Sse.last_event_id(request)` reads the `Last-Event-ID` of a client that connects again.
`Sse.from_events` sends a finite list. See [Streaming responses and server-sent events](../../docs/guides/streaming.md).

`with_event` rejects CR/LF and `with_id` rejects CR/LF/NUL so a field value cannot inject another SSE field.
Event data accepts CRLF, CR, and LF and encodes every resulting line with its own `data:` prefix.
`Sse.Event` is opaque: construct it with `Sse.event` and the validated `with_*` functions.

Each event is written whole, and a keep-alive comment never goes into the middle of one. Memory includes the current
encoded event and any events held by the caller. The host's response write deadline (30 seconds by default) applies
to each write.
