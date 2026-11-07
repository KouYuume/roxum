# Routing

A `Router(model, tag, provided)` maps request paths and methods to handlers. It is an immutable value built when the
app is compiled, so a mistake such as a duplicate route stops the build instead of surfacing at run time.

`tag` is the type of the [tags](middleware.md#tags-and-provided-values) routes carry, and `provided` the type of the
values layers leave for handlers. An app with neither writes `Router(Model, [], {})`. `Router.build` closes a router
for the platform, with the value `provided` starts from for each request:
`program = { init!, routes: Router.build(routes, {}) }`.

The code on this page is from [`tests/guide/routing.roc`](../../tests/guide/routing.roc); `zig build test-m13b`
builds it and checks the behavior described here.

## Routes

```roc
routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("home\n"))))
		.route(
			"/users/{id}",
			MethodRouter.methods([
				MethodRouter.get(Handler.pure(show_user)),
				MethodRouter.delete(Handler.pure(delete_user)),
			]),
		)
		.route("/users/me", MethodRouter.get(Handler.static(|{}| Reply.text("me\n"))))
		.route("/files/{*rest}", MethodRouter.get(Handler.pure(show_file)))
		.nest("/api", api)
		.fallback(
			|reason, _model, _head|
				match reason {
					Router.Unmatched.NotFound => Ok(Reply.text("nothing here\n").with_status(404))
					Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.status(405))
					Router.Unmatched.BadPath => Ok(Reply.status(400))
				},
		)

api : Router(Model, [], {})
api =
	Router.new
		.route("/health", MethodRouter.get(Handler.static(|{}| Reply.text("ok\n"))))
```

### Patterns

| Segment | Matches | Example |
|---|---|---|
| `users` | exactly that segment | `/users` |
| `{id}` | one segment, available as the parameter `id` | `/users/42` |
| `{*rest}` | the rest of the path, not empty; must be last | `/files/docs/a.txt` gives `rest` = `docs/a.txt` |

When several patterns match, a static segment beats a parameter, and a parameter beats a catch-all. The order in
which routes are added does not matter: `/users/me` above wins over `/users/{id}` although it is added later. Two
routes with the same shape and method are a conflict.

A trailing slash counts: `/users` and `/users/` are different paths, and `/files` and `/files/` do not match
`/files/{*rest}`. [`roxum-normalize-path`](../../integrations/roxum-normalize-path/README.md) removes trailing slashes
before routing, for an app that wants that.

Static segments are compared after normalizing percent-encoding: an escaped unreserved character (`A-Z a-z 0-9 - .
_ ~`) is decoded and other escapes use uppercase hex. So `/%61dmin` reaches the static route `/admin`, including its
layers, rather than a `/{page}` route. `%2F` is never decoded for matching, so it cannot split a segment. A static
pattern segment cannot be `.` or `..`. The pattern `*` matches only `OPTIONS *`; `/*` is an ordinary path.

`Router.route` crashes on an invalid or conflicting pattern. Because `routes` is a top-level value, that crash is a
compile-time error that shows the message. `Router.try_route` returns the error instead.

### Parameters

Handlers find parameters in `context.path_params`, a list of `{ name, value }` with percent-decoding applied. A value
that does not decode to UTF-8, or that would decode to NUL or to a `.` or `..` segment (`%2e%2e`, `..%2F`), is
answered with 400 before the handler runs, so a decoded value is never a path-traversal step. A value can still contain `/` (from `%2F`); join it into a
file path only after checking it against what your handler expects:

```roc
show_user : RouteContext({}) -> Try(Reply, Reply)
show_user = |context| Ok(Reply.text("user ${param(context, "id")}\n"))

param : RouteContext({}), Str -> Str
param = |context, name|
	match List.first(List.keep_if(context.path_params, |p| p.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
```

[Extractors](extractors.md) do this with an error reply for a missing parameter, and `Extract.Path` converts the value
to the field's type.

To build a link to a route from the same pattern, see [`Path`](responses.md#links-to-a-route).

## Methods

`MethodRouter.get`, `post`, `put`, `delete`, `patch`, `head`, `options`, and `query` each register one method;
`MethodRouter.methods` lists them for one path.

The router picks the path first and then the method:

- `HEAD` uses the `GET` handler when there is no explicit `HEAD` handler, and the host sends no body
- a path that exists without the requested method answers `405 Method Not Allowed` with an `Allow` field listing
  the methods it has (for `POST /users/42` above: `Allow: GET, HEAD, DELETE`)
- a path that does not exist answers `404`, or runs the fallback

`OPTIONS` is not answered automatically; register it when you need it. The host answers `CONNECT`, `TRACE`, and any
other method it does not know with `501` before Roc code runs, so no route can have them.

`MethodRouter.get(handler).tags([...])` gives a handler [tags](middleware.md#tags-and-provided-values) for layers to read.

## Composing routers

- `Router.nest(parent, "/api", child)` mounts `child` under a prefix: `/api/health` above
- `Router.merge(left, right)` combines two routers at the same level
- `Router.layer(router, stages)` and `Router.add_tags(router, tags)` apply only to what is written above them (see
  [Middleware](middleware.md#applying-layers))
- `Router.fallback(router, answer!)` answers when no handler can be called. It gets the reason
  (`Router.Unmatched.NotFound`, `MethodNotAllowed(methods)`, or `BadPath`), the model, and the request's metadata; the
  body is not received. `Allow` is added to a `405` that has none
- `Router.before_routing(router, check!)` runs for every request before the route is found, so it may change the path
  that is matched (see [Middleware](middleware.md#before-routing))

A handler under a prefix reads the path as it arrived: `Extract.path` is `/api/health`, not `/health` as in axum. So the
path means the same in a layer, in a handler, and in a log, and a link built from it is right. There is no extractor for
the prefix; a router mounted in several places that needs it takes it as an argument of the function that makes the router.

A nested router keeps its layers and its fallback: the layers cover the routes registered in it, and its fallback
answers under its prefix. A router passed to `merge` keeps its layers too, but it has no paths of its own, so `merge`
rejects one with a fallback. When two merged routers share a path, a `405` for it goes to the merged router's
fallback and through neither side's layers. A router with `before_routing` checks can be neither nested nor merged.
