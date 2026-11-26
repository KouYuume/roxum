# roxum-sse

`roxum-sse` builds `text/event-stream` replies and encodes events for roxum's
response writer. The host handles backpressure, timeouts and disconnects.

```roc
import sse.Sse

events = |_context|
	Ok(Sse.reply(|sse| {
		Sse.send!(sse, Sse.event("first"))?
		Sleep.millis!(1_000)
		Sse.send!(sse, Sse.event("second\nline") |> Sse.with_retry(1000))
	}))
```

`Sse.from_events` sends a finite list. For a live feed, use `Sse.reply` as above.
See the [streaming guide](../../docs/guides/streaming.md#server-sent-events) for keep-alive
and retry settings, reconnection with event IDs, and publishing from another request.

`with_event` rejects CR/LF and `with_id` rejects CR/LF/NUL so a field value cannot inject another SSE field.
Event data accepts CRLF, CR, and LF and encodes every resulting line with its own `data:` prefix.
`Sse.Event` is opaque: construct it with `Sse.event` and the validated `with_*` functions.

Each event is written whole, and a keep-alive comment never goes into the middle of one. Memory includes the current
encoded event and any events held by the caller. The host's response write deadline (30 seconds by default) applies
to each stalled write on HTTP/1 and to the entire response on HTTP/2.
