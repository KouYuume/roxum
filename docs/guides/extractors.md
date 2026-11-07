# Extractors

An extractor turns part of a request into a typed value, or into an error reply. A handler made with `Handler.typed`
says what it reads by the type of its argument. A handler made with `Handler.effectful` gets the model and the
`RouteContext`, and runs the extractors it needs with `Extract.run!`.

`Extract.run!` has effects, so `Handler.pure`, whose only argument is the `RouteContext`, and `Handler.stateful`, which
gets the model and the `RouteContext`, cannot call it. They read the context directly, such as `context.path_params`.

The code on this page is from [`tests/guide/extractors.roc`](../../tests/guide/extractors.roc); `zig build
test-m13b` builds it and checks the behavior described here.

## Handlers with a typed argument

`Handler.typed` makes a handler whose one argument, a record, says by its field types what to read from the request:

```roc
routes : Router(Model, [], {})
routes =
	Router.new
		.route(
			"/lists/{list}/items",
			MethodRouter.post(Handler.typed(add_item!))
				# Refuses a non-JSON Content-Type before the body is received.
				.layer(Extract.require_json({})),
		)
		.route("/lists/{list}/search", MethodRouter.get(Handler.typed(search!)))

add_item! : Model, { list : Extract.Path(Str), item : Extract.JsonBody(NewItem) } => Try(Reply, Reply)
add_item! = |_model, { list: Extract.Path.(list), item: Extract.JsonBody.(item) }|
	Ok(Reply.text("added ${item.name} to ${list}\n").with_status(201))
```

A field that cannot be read answers with its error, and the handler does not run.

| Field type | Reads | Fails with |
|---|---|---|
| `Extract.Path(value)` | the path parameter with the field's name, as a `Str`, number, or `Bool` | 400 when it does not fit, 500 when the route has no such parameter |
| `Extract.Query(value)` | the query string, percent-decoded, into a record | 400, also past 8 KiB or 128 fields |
| `Extract.Form(value)` | an `application/x-www-form-urlencoded` body, into a record | 415, 413 past 2 MiB or 128 fields, 422 when it does not fit |
| `Extract.JsonBody(value)` | a JSON body | 415, 400 |
| `Extract.Headers(value)` | the header fields, into a record | 400 |
| `Extract.Multipart(value)` | a `multipart/form-data` body, into a record | 415, 400, 413, 422 |
| `Extract.Bytes`, `Extract.Text` | the whole body | as `Extract.bytes`, `text` |

`Query` and `Form` records hold `Str`, numbers, `Bool`, a `List` for a name that repeats, and `Try(_, [Missing])` for
a name that may be left out. A name the record does not have is ignored; a single value that repeats fails. A `GET` form
arrives in the query, so `Extract.Form` reads only the body.

A field that cannot be read answers for itself, and the handler does not run. To decide in the handler, give the field the
type `[Ok(_), Err(Reply)]`. `Err` holds the reply roxum would have sent; send it, or send your own. Other fields answer as
usual. It cannot be `Try(_, Reply)`: Roc derives a `Try` only as an optional field, as in `Try(_, [Missing])`. For the same
reason, read the field with `match`; `?` makes its type a `Try`.

```roc
create! : Model, { item : [Ok(Extract.JsonBody(Item)), Err(Reply)] } => Try(Reply, Reply)
create! = |_model, { item }|
	match item {
		Ok(Extract.JsonBody.(value)) => Ok(Reply.json(value))
		Err(_) => Ok(Reply.json({ error: "invalid_item" }).with_status(400))
	}
```

Reading has no effects: the body has been received. A value that needs effects, such as a user from a database, comes
from a `BeforeBody` stage through `RequestHead.provided` (see [Middleware](middleware.md#tags-and-provided-values));
`Extract.reading` defines a custom field parser from a function of the `RouteContext`.
Annotate `parser_for` with `Extract.Parser(MyType, provided)` when an explicit signature is needed;
the record decoder and its state are internal implementation details.

Handlers can also run extractors in their body with `Extract.run!`. The type comes from the variable:

```roc
add_item! = |_model, context| {
	item : NewItem
	item = Extract.run!(Extract.json({}), context)?
	...
}
```

## Built-in extractors

| Extractor | Value | Fails with |
|---|---|---|
| `Extract.path_param(name)` | the percent-decoded path parameter | 500 when the route has no such parameter (a bug in the app) |
| `Extract.path` | the request path | — |
| `Extract.query_str` | the raw query string, without `?`, not percent-decoded | 400 when it is not UTF-8 |
| `Extract.headers` | all request header fields; names are lowercase | — |
| `Extract.typed_headers({})` | a record decoded from the header fields | 400 when they do not match |
| `Extract.bytes` | the whole body | 413 over `Server.Limits.maximum_body_bytes` (2 MiB) or the route's `BodyLimit.whole`, 408 on timeout, 400 when malformed |
| `Extract.text` | the whole body as UTF-8 | as `bytes`, and 400 when not UTF-8 |
| `Extract.json({})` | a value decoded from a JSON body | 415 for missing, duplicate, malformed, or non-JSON Content-Type; otherwise as `text`, and 400 when decoding fails |
| `Extract.query({})` | the query string decoded into a record | 400 |
| `Extract.form({})` | a form body decoded into a record | 415, 413, 422 |
| `Extract.multipart({})` | a `multipart/form-data` body decoded into a record | 415, 400, 413, 422 |
| `Extract.provided(pick)` | a value a `BeforeBody` stage left in `provided` ([Middleware](middleware.md#tags-and-provided-values)) | 500 when no stage set it |
| `Extract.optional(pick)` | the same, for a value a stage may leave out on purpose | 500 when no stage ran |
| `Extract.request` | the whole `Request` | — |

roxum receives the whole body before the handler runs, so reading it does not wait on the network, and running a body
extractor twice gives the same bytes. A body over its limit, or one that does not arrive within its timeout, is
answered `413` or `408` before the handler runs (see [Deployment](deployment.md#keep-alive-and-timeouts)). The limits
in the table apply at that point.

## Decoding JSON

A nominal record type declares `parser_for` to let Roc derive the decoder:

```roc
NewItem := { name : Str }.{
	parser_for : _
}
```

`Extract.json` requires exactly one `Content-Type: application/json` or `application/*+json` field.
Type names are case-insensitive and valid parameters (such as `charset=utf-8`) are allowed.
It rejects other media types with 415; clients must send this header. By then the body has been received.
`Extract.require_json({})` is a layer with the same check that answers before the body is received, so a client that
sent `Expect: 100-continue` never sends it. `Extract.require_form({})` does the same for a form.

A body that is not valid JSON, does not match the type, or lacks a required field gets `400`. These are one status
because Roc's `Json.parse` reports syntax errors and type mismatches the same way. `Extract.JsonBody` answers before the
handler runs; `Extract.json({})` returns the reply as an `Err`, which `?` passes on.

## Forms with files

`Extract.Multipart(value)` reads a `multipart/form-data` body whole into a record. A file field is an `Extract.Upload`, with
`filename` and `content_type`, each a `Try` because a client may leave them out, and `bytes`. `filename` is what the
client wrote: never use it as a path.

```roc
update! : Model, { form : Extract.Multipart({ name : Str, icon : Extract.Upload }) } => Try(Reply, Reply)
update! = |model, { form: Extract.Multipart.(form) }| save!(model, form.name, form.icon.bytes)
```

It answers `415` without a `multipart/form-data` Content-Type and boundary (`Extract.require_multipart({})` does so before
the body is received), `400` for a malformed body, `413` past the whole-body limit or 128 fields, and `422` for a body
that does not fit the record.

An upload too large to hold goes field by field with `Multipart.streaming`:

```roc
upload = Handler.streaming(Multipart.streaming(Multipart.Callbacks.{
	begin!: |model, _head| open_storage!(model),
	field!: |state, head| start_field!(state, head.name),
	chunk!: |state, bytes| write_part!(state, bytes),
	done!: |_model, state| finish!(state),
}))
```

`abort!` may be added as for `Handler.streaming`, and `limits: MultipartBody.Limits.{ max_field_bytes: ... }` bounds the
fields, a field's headers, and a field's bytes. The body's own limit is `Server.Limits` or `BodyLimit.streamed`.

## Compressed request bodies

`Compression.decompress_requests(maximum_bytes)` is a layer that decompresses a body sent with `Content-Encoding: gzip` or
`zstd` before the handler reads it. Past `maximum_bytes` it answers `413`, for an invalid body `400`, and for another
coding `415` before the body is received. A `Handler.streaming` handler gets the parts as they were sent.

## Cookies

Cookies are in the optional [`roxum-cookie`](../../integrations/roxum-cookie/README.md) package. Its `Cookie.Read` is a
field type for `Handler.typed`, and `Cookie.get` reads one cookie from the headers:

```roc
show! : Model, { cookies : Cookie.Read({ theme : Try(Str, [Missing]) }) } => Try(Reply, Reply)
show! = |_model, { cookies: Cookie.Read.(cookies) }| ...
```

## Combining extractors

- `Extract.map(extractor, transform)` changes the value
- `Extract.map2` / `Extract.map3` combine two or three extractors into one value
- `Extract.and_then(extractor, next)` chooses the next extractor from a value, for example to validate a parameter

Write your own extractor as `Extractor.{ run!: |context| ... }` returning `Ok(value)` or `Err(reply)`.
