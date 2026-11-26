# Streaming bodies and server-sent events

A handler can write its response body as it goes instead of returning it whole: a large download, a report built row
by row, or [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) that never end.
While the body waits, for a sleep or an outbound call, the request's thread serves other requests. It can also read
a large request body, such as an upload, in parts as it arrives.

Choose the API according to which side produces data incrementally:

| Use case | API | Protocol |
|---|---|---|
| Upload a request in parts | [`Handler.streaming`](#reading-a-large-request-body) | HTTP/1 and HTTP/2 |
| Send a response in parts | [`Reply.stream`](#writing-a-body) | HTTP/1 and HTTP/2 |
| Send server-sent events | [`roxum-sse`](#server-sent-events) | HTTP/1 and HTTP/2 (periodic keep-alive comments require HTTP/1) |
| Keep reading while response output is blocked | [`Handler.duplex`](#independent-http2-input-and-output) | HTTP/2 |

## Independent HTTP/2 input and output

Use `Handler.duplex({ begin!, ready! })` when input must keep progressing while
the peer has stopped reading output. `begin!` receives the model and request
head and returns `Ok({ state, status, headers, interest })`, or an error reply.
Choose `Handler.Interest.Read`, `Write` or `Both`.

`ready!(state, event, writer)` receives input as `Idle`, `Chunk(bytes)`,
`End` or `Failed(reason)`, plus `event.writable`. Return
`Handler.DuplexNext.Await({ state, interest })` to continue, or
`Handler.DuplexNext.Finish(trailers)` to complete. After End or Failed, select
Write only or finish. Choose Read when there is no output to produce; repeatedly
asking for unused write readiness can spin.

Use `ResponseWriter.try_write!` with at most 16 KiB per call. Accepted means
the host copied the bytes; Pending retains nothing, so preserve the unsent bytes
in your state. Readiness is a hint, so a try-write can still return Pending after
a writable event. A pending write does not prevent processing input. Blocking
`write!` is still available but can stall your input processing. Return Finish
rather than calling `finish!` yourself from the readiness callback.

`OnChunk` transformations and EOF checks run normally. A rejection after
headers resets the stream; a body-limit failure is delivered as Failed so you
can finish with application-specific trailers. Response middleware runs before
headers, and AfterBody does not run. Reset, timeout and disconnect cancel the
request and release held permits. Returning Err(StreamClosed) aborts the stream.
HTTP/1 answers 501 without running the duplex callbacks.

The [production fixture](../../tests/http2-listener/app.roc) demonstrates a
bounded counter and output producer; its client withholds output credit while
sending input larger than the connection window. The transport and lifetime
contracts are in [HTTP/2 streaming](../design/http2-streaming.md).

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

The body uses chunked framing on HTTP/1.1 or DATA frames on HTTP/2, and ends after
the function returns. `ResponseWriter.write!` waits when output cannot progress.
On HTTP/1, a disconnected client or a stalled write returns `Err(StreamClosed)`.
On HTTP/2, cancellation abandons the request fiber, so application code after a
blocked write does not resume. `Server.Timeouts.response_write_milliseconds`
(30 seconds by default) limits a stalled HTTP/1 write or the whole HTTP/2 response.

If the client goes while the function waits for anything else, such as `Sleep` or `Tcp`, the function stops at that
wait: the code after it never runs, and what the request held is given back. The access log says `client_closed`.

`Server.Limits.maximum_streams` caps the bodies a worker writes at once; past it, the request is answered 503
(`stream_limit` in the access log).

`Reply.json_lines` is the same for [JSON Lines](responses.md#json-lines).

On HTTP/2, use uncompressed output. To attach trailers,
call `ResponseWriter.finish!(writer, trailers)` inside the callback. Invalid
trailers can be corrected and retried. Successful finish closes the writer after
terminal output is written to the socket. Returning `Err(StreamClosed)` aborts
unfinished output on either protocol. For execution expiry after headers, see
[HTTP/2 streaming](../design/http2-streaming.md).

### Options

`Reply.stream_with` accepts the following writer options:

| field | default | |
|---|---|---|
| `keep_alive` | `ResponseWriter.KeepAlive.None` | `Every({ milliseconds, bytes })` (HTTP/1 only) writes `bytes` each time `milliseconds` pass without a write, so proxies keep a quiet connection |
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

For HTTP/2, set `keep_alive: Sse.KeepAlive.Off`. Graceful drain works on both protocols.

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
| in parts | `Handler.streaming` | `maximum_streamed_body_bytes`, `Server.BodyLimit.Unlimited` | HTTP/1: each wait for bytes; HTTP/2: entire input from metadata completion |

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
  does not run after a handler crash or an HTTP/2 transport reset, timeout or disconnect.

`AfterBody` stages do not run for a streaming handler: there is no whole body to give them.

On HTTP/1, unless the client sent `Expect: 100-continue`, the host first reads a `Content-Length` body of up to 64 KiB, or the first
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

On HTTP/1, an early reply from `begin!` or `chunk!` closes the connection after the response unless the remaining input has already arrived. On HTTP/2, early replies affect only the request stream. A finite reply discards unfinished input within transport limits. A streamed reply sends its terminal output before closing unfinished input with `RST_STREAM(NO_ERROR)`.
