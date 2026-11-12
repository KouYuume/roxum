# Streaming bodies and server-sent events

A handler can write its response body as it goes instead of returning it whole: a large download, a report built row
by row, or [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) that never end.
While the body waits, for a sleep or an outbound call, the request's thread serves other requests. It can also read
a large request body, such as an upload, in parts as it arrives.

`zig build test-stream-limit` and `zig build test-graceful-shutdown` check the streams themselves, and
`zig build test-m9p4` runs the server-sent events example in
[`integrations/roxum-sse/example`](../../integrations/roxum-sse/example/app.roc).

HTTP/2 currently supports finite bodies. Routing and `BeforeBody` stages run
before input EOF; a body read suspends until the complete bounded input arrives.
`Handler.streaming` can then consume that collected body in parts, but does not
receive incremental network data. The streamed-read default comes from
`maximum_streamed_body_bytes`; route layers can replace that default, but
`maximum_body_bytes` remains a hard HTTP/2 cap.
`Unlimited` cannot remove that finite-input cap. Response writers and file streams
remain unsupported on HTTP/2. The incremental streaming examples below use HTTP/1.

## Writing a body

`Reply.stream` takes the function that writes the body. The handler returns the reply; middleware still sees and
changes its status and headers; then the platform sends the head and calls the function.

```roc
import pf.Reply
import pf.ResponseWriter
import pf.Sleep

report = |_context|
	Ok(Reply.stream(|writer| {
		ResponseWriter.write!(writer, "first\n".to_utf8())?
		Sleep.millis!(1_000)
		ResponseWriter.write!(writer, "second\n".to_utf8())
	}))
```

The body goes out chunked (HTTP/1.1) and ends when the function returns. `ResponseWriter.write!` waits while the
client does not take the bytes, and returns `Err(StreamClosed)` when the client is gone or took nothing for
`Server.Timeouts.response_write_milliseconds` (30 seconds by default); the stream is then over.

If the client goes while the function waits for anything else, such as `Sleep` or `Tcp`, the function stops at that
wait: the code after it never runs, and what the request held is given back. The access log says `client_closed`.

`Server.Limits.maximum_streams` caps the bodies a worker writes at once; past it, the request is answered 503
(`stream_limit` in the access log).

`Reply.json_lines` is the same for [JSON Lines](responses.md#json-lines).

### Options

`Reply.stream_with` takes `ResponseWriter.Options`:

| field | default | |
|---|---|---|
| `keep_alive` | `ResponseWriter.KeepAlive.None` | `Every({ milliseconds, bytes })` writes `bytes` each time `milliseconds` pass without a write, so proxies keep a quiet connection |
| `ends_on_drain` | `Bool.False` | when the server stops, end the body at the function's next wait |

The keep-alive bytes are a part of the body like any other, so they must mean nothing to the client (an SSE comment,
a blank line of NDJSON). They never go into the middle of a write.

### Stopping the server

When the server drains ([Deployment](deployment.md)), it waits for every body to end, as it does for any request.
A body with `ends_on_drain: Bool.True` ends at the function's next wait instead (the code after it never runs), with
a clean end the client can tell from a cut connection; the access log says `drained`. Use it for a body with no end,
whose client connects again, to another worker. A download keeps the default and is written whole.

## Server-sent events

[`roxum-sse`](../../integrations/roxum-sse/README.md) writes `text/event-stream` bodies. By default a stream sends a
keep-alive comment (`:`) every 15 seconds without an event, and ends when the server stops, so a browser's
`EventSource` connects again to another worker.

```roc
import pf.Instant
import pf.Sleep
import pf.Time
import sse.Sse

clock = |_context|
	Ok(Sse.reply(|sse| send_time!(sse, Instant.now!({}))))

send_time! = |sse, at| {
	now = Time.now!({}).to_unix_milliseconds()
	Sse.send!(sse, Sse.event(now.to_str()))?
	next = at.add_milliseconds(1_000)
	# Sleeping until the next second, not for a second, keeps the time a send
	# takes from adding up.
	Sleep.until!(next)
	send_time!(sse, next)
}
```

`Sse.reply_with(Sse.Options.{ ... }, send_events!)` changes the defaults:

| field | default | |
|---|---|---|
| `keep_alive` | `Sse.KeepAlive.Every(15_000)` | `Sse.KeepAlive.Off` sends no comments |
| `retry_milliseconds` | `Sse.Retry.None` | `Sse.Retry.Value(ms)` sends a `retry` field first: how long the client waits before it connects again |
| `ends_on_drain` | `Bool.True` | `Bool.False` makes a drain wait for the stream to end |

`Sse.with_retry` sets `retry` on a single event instead.

### Going on after a reconnection

Give events an `id` with `Sse.with_id`. A client that connects again sends the last `id` it received, and
`Sse.last_event_id(context.request)` reads it: `Err(Missing)` on a first connection. The example's `/ticks` route
does this with `send_ticks!`.

```roc
ticks = |context| {
	first = match Sse.last_event_id(context.request) {
		Ok(last) =>
			match U64.from_str(last) {
				Ok(number) => number + 1
				Err(_) => 0
			}
		Err(_) => 0
	}
	Ok(Sse.reply(|sse| send_ticks!(sse, first)))
}
```

What an `id` means, and whether the events after it can still be sent, is the app's to decide.

## Reading a large request body

A handler made with `Handler.pure`, `stateful`, `effectful`, or `static` runs after the router has received the whole
body (see [Middleware](middleware.md#the-body)). A body too large to hold is read by a `Handler.streaming` handler
instead, which gets it part by part as it arrives; while it waits for the client, the thread serves other requests.
A client that sent `Expect: 100-continue` gets `100 Continue` when the body is first read, after the `BeforeBody`
stages accepted the request.

Each way has its own limit in `Server.Limits`:

| | handler | limit | time limit (`Server.Timeouts.request_body_milliseconds`, 30 s) |
|---|---|---|---|
| whole | `Handler.pure`, `stateful`, `effectful`, `static` | `maximum_body_bytes`, 2 MiB | the whole body |
| in parts | `Handler.streaming` | `maximum_streamed_body_bytes`, `Server.BodyLimit.Unlimited` | each wait for bytes |

A body past its limit is answered with `413`; a body whose `Content-Length` is over the limit fails at the first
read, before `100 Continue`. A streaming handler holds only the part it is given, so an upload of any size takes
little memory; the request's memory limit still holds.

```roc
upload = Handler.streaming(Handler.Streaming.{
	begin!: |model, _head| open_upload!(model.storage),
	chunk!: |upload, bytes| write_part!(upload, bytes),
	done!: |_model, upload| {
		finish_upload!(upload)?
		Ok(Reply.status(201))
	},
	abort!: |upload, _reason| discard_upload!(upload),
})
```

- `begin!` runs before the body is received, with the request's metadata, and returns the state to start from or a
  reply to answer at once.
- `chunk!` gets the state and the next part, and returns the next state. `OnChunk` stages have already passed it.
- `done!` runs after the whole body arrived and returns the reply.
- `abort!`, which may be left out, runs when the request ends before `done!`: the client disconnected or sent an invalid body
  (`BadRequest`), the body passed its limit (`TooLarge`), the body timeout passed (`TimedOut`), a host failure
  (`Failed`), or a stage or `chunk!` rejected it (`Rejected`). The platform answers with the matching status. It
  does not run if the handler crashes.

`AfterBody` stages do not run for a streaming handler: there is no whole body to give them.

Unless the client sent `Expect: 100-continue`, the host first reads a `Content-Length` body of up to 64 KiB, or the first
64 KiB of a chunked body ([Middleware](middleware.md#the-body)). If the connection is cut during that read, no Roc code
runs: neither `begin!` nor `abort!` is called.

A `multipart/form-data` upload goes field by field with
[`Multipart.streaming`](extractors.md#forms-with-files), which makes the callbacks for `Handler.streaming`.

### Limits for a route

`BodyLimit.whole(bytes)` and `BodyLimit.streamed(limit)` change the limits for the routes they are layered on, with
`MethodRouter.layer` for one route or `Router.layer` for all; the layer nearer the handler wins.

```roc
Router.route(
	"/files",
	MethodRouter.post(upload)
		.layer(BodyLimit.streamed(Server.BodyLimit.Bytes(1_073_741_824))),
)
```

A streaming handler that answers before the whole body arrived (from `begin!`, or a `chunk!` that returns a reply)
closes the connection after its response, unless the rest is already received.
