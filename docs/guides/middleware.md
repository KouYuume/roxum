# Middleware

A layer does work around a handler at the stages of a request. It is a list of `Middleware.Stage` values, so a
layer can inspect and change the request's metadata, the body, and the reply as values.

The code on this page is from [`tests/guide/middleware.roc`](../../tests/guide/middleware.roc); `zig build
test-m13b` builds it and checks the behavior described here.

## Stages

A request runs the stages in this order, whatever order the layers are written in:

| Stage | Runs | Callback |
|---|---|---|
| `BeforeBody` | before the body is received, with the metadata only | `\|model, head\| Try(head, Reply)` |
| `OnChunk` | on each part of the body as it arrives | a `Middleware.ChunkCheck` |
| `AfterBody` | with the whole body, before the handler | `\|model, head, body\| Try(body, Reply)` |
| `AfterHandler` | on the reply on its way out | `\|model, head, reply\| reply` |

`head` is a `RequestHead`: the request without its body. `BeforeBody` returns the head to go on with, possibly
changed, or a reply to answer at once; the body is then not received, and a client that sent
`Expect: 100-continue` never sends it. `AfterBody` returns the body to pass on, possibly transformed, or a reply.
A body the host reads ahead may already have arrived when `BeforeBody` runs; see [The body](#the-body).

The callbacks of `BeforeBody`, `AfterBody`, and `AfterHandler` may perform effects. Pass a function annotated as
pure (`->`) in a lambda, such as `|model, head| Ok(check(model, head))`.

## Writing a layer

```roc
tag_reply : HeaderName, HeaderValue -> List(Middleware.Stage(Model, [], {}))
tag_reply = |name, value| {
	header = ResponseHeader.{ name, value }
	[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [header]))]
}

require_key : List(Middleware.Stage(Model, [], {}))
require_key = [
	Middleware.Stage.BeforeBody(
		|_model, head|
			if List.any(head.headers, |field| field.name == HeaderName.("x-api-key")) {
				Ok(head)
			} else {
				Err(Reply.text("missing x-api-key\n").with_status(401))
			},
	),
]
```

A layer with work at more than one stage lists them together, such as a CORS layer that answers preflight requests
in `BeforeBody` and adds fields to other replies in `AfterHandler`. The stages of one layer share its position: a
reply the layer's own `BeforeBody` made does not go through its own `AfterHandler`.

## Applying layers

```roc
routes =
	Router.new
		.route("/public", MethodRouter.get(Handler.static(|{}| Reply.text("public\n"))))
		.route(
			"/private",
			MethodRouter.get(Handler.static(|{}| Reply.text("private\n")))
				.layer(require_key),
		)
		.layer(tag_reply(HeaderName.("x-served-by"), "roxum"))
```

- `MethodRouter.layer` adds a layer around the handlers already in that method router
- `Router.layer` adds a layer around what is written above it: the routes with their `405` and `400` replies, what
  `nest` and `merge` added, the fallback, and the default `404`, which stands where `Router.new` is written. A route
  added later is not inside it, so write the routes a layer should protect above it
- Within one stage, layers run in the order they are written: the layer written first is outermost, and a reply goes
  out through the `AfterHandler` stages of the layers written before the point where it was made. A layer that
  should see every reply, such as a log, is written first. A route's own layers are inside the router's.

## Before routing

`Router.before_routing` runs a check for every request before the route is found, wherever it is written. It may
change the path that is matched, or answer at once; that reply goes through no layer. Only the router the app hands
to the platform can have one. `roxum-normalize-path` and `roxum-proxy-headers` provide such checks; neither runs unless
added, since a path rewrite is the app's policy and the trusted proxies are the app's to name.

## The body

A handler made with `Handler.pure`, `stateful`, `effectful`, or `static` runs after the router has received the
whole body. The extractors read that body, so extracting it twice gives the same bytes. A body over its limit
(`Server.Limits.maximum_body_bytes`, 2 MiB by default, or `BodyLimit.whole`) is answered with `413` before the
handler runs.

Unless the client sent `Expect: 100-continue`, the host first reads a `Content-Length` body of up to 64 KiB, or the first
64 KiB of a chunked body, without running Roc code. On such a request, `BeforeBody` runs after those bytes arrived, and
if they never arrive the answer is `408`, even on a route whose `BeforeBody` would refuse the request. A longer
`Content-Length` body, or a request with `Expect: 100-continue`, reaches `BeforeBody` when the head is complete, so a
refusal does not wait for the body.

A body too large to hold is read by a `Handler.streaming` handler, part by part; see [Streaming](streaming.md).

`OnChunk` stages check or transform the parts as they arrive. `Middleware.ChunkCheck.new` takes the state each
request starts from, a function from the state and a part to the new state and the bytes to pass on, and an end
check. A check that returns a reply stops the request.

## Tags and provided values

A route can carry values that mean nothing to roxum and everything to a layer, and a layer can leave values for the
handler. Both types are the app's:

```roc
Tag : [RateLimit(U32), MembersOnly]
Provided := { user : Try(User, [Unset]) ?? Err(Unset) }

routes : Routes(Model)
routes =
	Router.new
		.route("/login", MethodRouter.post(Handler.effectful(login!)).tags([RateLimit(5)]))
		.route(
			"/articles/{id}",
			MethodRouter.methods([
				MethodRouter.get(Handler.effectful(show!)).tags([RateLimit(100)]),
				MethodRouter.delete(Handler.effectful(remove!)).tags([RateLimit(5)]),
			]).tags([MembersOnly]),
		)
		.layer(require_member)
		.build(Provided.{})

require_member = [
	Middleware.Stage.BeforeBody(
		|model, head|
			if List.contains(head.tags, MembersOnly) {
				user = find_user!(model, head)?
				Ok({ ..head, provided: Provided.{ user: Ok(user) } })
			} else {
				Ok(head)
			},
	),
]

show! = |model, context| {
	user = Extract.run!(Extract.provided(|p| p.user), context)?
	...
}
```

- `MethodRouter.tags` adds tags to the handlers already in that method router. A `405` for the path has no method, so it
  sees only `Router.add_tags`, which covers what is written above it, as `Router.layer` does
- `Extract.provided` answers `500` when the value was not set: a layer or tag is missing from the route. This is checked
  when a request arrives, not when the app is built. A protected route is safer with a test for it
- `Extract.optional` tells a value a layer left out on purpose (`Err(Anonymous)`) from a missing layer (`Err(Unset)`,
  `500`), for a page that also works without a user
- `Router.build(router, initial)` closes the router over these types. `initial` is what `provided` starts from for each
  request: `{}` when the app has no provided values

[`examples/middleware`](../../examples/middleware/README.md) is a complete app built this way, with a handler that reads the
provided user through a field type, and with `roxum-rate-limit` counting per user.

The types read `Router(Model, Tag, Provided)` and `RouteContext(Provided)`. Name them once if annotations get long:
`AppRouter : Router(Model, Tag, Provided)`. An app with neither writes `Router(Model, [], {})`, or leaves annotations out.

## Rate limits

`RateCounter` keeps counts per key in the host, and [`roxum-rate-limit`](../../integrations/roxum-rate-limit/README.md)
turns a route's tag into a check that answers `429`. Make the counter in `init!` and keep it in the model:

```roc
per_minute = RateCounter.new!({ window_seconds: 60, max_keys: 100000 })?
```

```roc
routes =
	Router.new
		.route("/search", MethodRouter.get(search).tags([Limit(100)]))
		.layer(RateLimit.layer(|model, head, tag|
			match tag {
				Limit(limit) => Ok(RateLimit.Check.{
					counter: model.per_minute,
					key: match head.remote_addr {
						Tcp({ ip, .. }) => "search:${RateLimit.client_ip(ip)}"
						Unix => "search:unix"
					},
					limit,
					on_full: RateLimit.OnFull.Allow,
				})
			}))
```

Each process has its own counts, and a restart starts from nothing. With the default of one process that is the whole
instance. With more `processes` or more instances, the limit applies to each.

## Limits on requests at once

`Concurrency` holds keys in the host, and [`roxum-concurrency-limit`](../../integrations/roxum-concurrency-limit/README.md)
turns a check into `503` for a request over the limit. Make the limiter in `init!` and keep it in the model.

```roc
limiter = Concurrency.new!({ max_keys: 100000 })?
```

```roc
MethodRouter.get(Handler.effectful(export!))
	.layer(ConcurrencyLimit.layer(|model, _head|
		Ok(ConcurrencyLimit.Check.{
			limiter: model.limiter,
			key: "export",
			limit: 5,
			on_full: ConcurrencyLimit.OnFull.Reject,
		})))
```

A request holds its key until it ends, a streamed body included. The host gives it back however the request ends, so a crash
or a client that went away cannot leave a key held. A request over the limit does not wait. Each process has its own limiters.

## Layers in the platform

| Layer | Stage | Does |
|---|---|---|
| `BodyLimit.whole(bytes)`, `BodyLimit.streamed(limit)` | `BeforeBody` | change a route's [body limits](streaming.md#limits-for-a-route) |
| `Extract.require_json({})`, `require_form({})`, `require_multipart({})` | `BeforeBody` | answer `415` for another Content-Type ([Extractors](extractors.md)) |
| `Compression.decompress_requests(maximum_bytes)` | `BeforeBody`, `AfterBody` | decompress a gzip or zstd request body ([Extractors](extractors.md#compressed-request-bodies)) |
| `Compression.layer(options)` | `AfterHandler` | compress responses ([Files](files.md#compressing-responses)) |

## Limits

Handlers run synchronously on one of the process's threads. A layer runs before and after the handler, but it
cannot interrupt a handler that is still running: a timeout layer can only react after the handler returns. roxum has
no timeout that stops a running handler.

## Integration packages

Common pieces are separate packages, so an app only depends on what it uses:

| Package | Provides |
|---|---|
| `roxum-set-header` | fixed response header fields |
| `roxum-trace` | request IDs on responses, and a log line per request |
| `roxum-normalize-path` | trailing-slash normalization before routing |
| `roxum-cors` | CORS preflight and response fields |
| `roxum-cookie` | reading, setting, and signing cookies (not a layer) |
| `roxum-rate-limit` | `429` past a limit per key, from route tags |
| `roxum-concurrency-limit` | `503` past a limit of requests at once per key |
| `roxum-proxy-headers` | the client address behind a trusted reverse proxy |
| `roxum-sse` | server-sent events |

Each package declares the platform versions it works with, and the digest of the platform it was checked on; see
[`integrations/compatibility.json`](../../integrations/compatibility.json).

Unix peers have no IP address. The `unix` key above shares one limit across them; use an authenticated application identity when per-client limits are needed.
