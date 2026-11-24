# Migrating from 0.2 to 0.3

Use Roc `0.1.0_RC1` and Zig 0.17.1 as described in [toolchain setup](../toolchain.md),
and update application code as described in [Roc 0.1](#roc-01) below. Rebuild
with the 0.3 platform sources and host archives together; old host archives do
not match the new hosted ABI. For URL imports, use the platform and integration
URLs from the same `release.json`, including in generated services.

| Package | Version | Application action |
|---|---|---|
| roxum | 0.3.0 | Review HTTP/2 streaming handlers and response completion below. |
| roxum-grpc | 0.2.0 | Use the bundle targeting core `^0.3`. |
| roc-protobuf and protoc-gen-roc | 0.1.1 | Update the pair and regenerate bindings from the schema. |
| Other integrations | Existing package versions | Update bundle URLs to the builds targeting core `^0.3`. |

## Roc 0.1

### Listener settings

Roc 0.1 fills a record's default fields only where the record's type is known.
An `init!` without an annotation builds its `listen` record as a plain record,
which lacks `Server.ListenOptions`' defaults such as `access_log`. Annotate
`init!`, or build the record as `Server.ListenOptions.{ ... }`:

```roc
init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 8080 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})
```

### Handlers and extractors

A field that holds the reply of a field that failed can now be a `Try`, so `?`
sends that reply. A field typed `[Ok(_), Err(Reply)]` still works unchanged.

```roc
create! : Model, { item : Try(Extract.JsonBody(Item), Reply) } => Try(Reply, Reply)
```

`HttpError` is a record. Replace `HttpError.make(409, "...")` with
`HttpError.{ status: 409, message: "..." }`, and `HttpError.status(error)` and
`HttpError.message(error)` with `error.status` and `error.message`.
`Middleware.ChunkCheck.new` takes a record:

```roc
Middleware.ChunkCheck.new({
	initial: 0,
	step: |seen, bytes| Ok({ state: seen + List.len(bytes), bytes }),
	finish: |_seen| Ok({}),
})
```

### Parsers

Each format owns one closed error type, and every parser inside it, including a
custom `parser_for`, uses that type. Close open error rows in annotations:
`a.Json.Parseable([InvalidJson(Str), ..errs])` becomes
`a.Json.Parseable([InvalidJson(Str)])`. A format reports a missing required field
through its own error type: JSON as `InvalidJson("Missing field: name")`, and the
URL-encoded, multipart, TOML (`Toml.decode`), and PostgreSQL row formats as
`MissingRequiredField(name)`. Add `MissingRequiredField(Str)` where an annotation
lists the errors of `Toml.decode` or of `Postgres.query!`'s decoding.

A custom format defines `missing_field : encoding, Str -> err` when it reads
records, and `Encoding.ParseTagUnionSpec` takes the format's encoding, state,
and error types: `Encoding.ParseTagUnionSpec(a, MyFormat, MyState, MyError)`. A
custom parser that never fails takes its error type from the format, for
example with `where [encoding.missing_field : encoding, Str -> err]`.

### Other language changes

- A value of a nominal type built with a plain tag is a structural tag union.
  Qualify the tag where the value is built or compared, as in
  `result != Try.Err(OutputLimit)`.
- An argument with the name of a member of its type's `.{ … }` block shadows
  the member and is warned about. Rename the argument, or take a record.
- An expression that does not depend on a function's arguments is evaluated
  when the app is built, even inside the function. A computation meant to run
  per request must depend on the request.

### Interpreter builds

An app built with `--opt=interpreter` runs one thread per process, because Roc's
interpreter keeps a call on the thread that entered it. `Server.Threads.Fixed`
above 1 stops its startup; raise `processes` to use more CPUs. Builds with
`--opt=dev` and `--opt=speed` are unaffected.

## HTTP applications

HTTP/1 remains the default. Ordinary handlers still receive complete bodies.
Code that matches exhaustively on `Handler` variants must handle `Duplex`.
On HTTP/2, `Handler.streaming` receives chunks before EOF. In 0.2,
`maximum_body_bytes` capped these requests even when streamed reads were
unlimited. In 0.3 it caps whole-body reads. To keep the old upload ceiling,
set `maximum_streamed_body_bytes: Server.BodyLimit.Bytes(n)` to the previous
byte limit and review route overrides from `BodyLimit.streamed`. The default is
`Unlimited`.

The HTTP/2 request-body deadline
runs from metadata completion and includes time spent in callbacks. Choose a
deadline that covers the complete upload. Reset, timeout and disconnect abandon
suspended work. Keep cleanup of external resources within the request lifetime.

A `Reply.stream` producer should return `Ok({})` for a successful end.
Returning `Err(StreamClosed)` aborts unfinished output. On HTTP/2 the write
timeout covers the response as a whole. Complete required application I/O before
calling `ResponseWriter.finish!` with terminal trailers. See the
[streaming guide](streaming.md) for writer options and protocol limits.

## gRPC services

Unary-only generated registrations keep their handler and limits shape. When
adding a streaming method to a Unary service, regenerate its bindings and pass
`{ unary, streaming }` limits to `register`. The streaming configuration bounds
message size, message count, cumulative payload and duration. See the
[greeting service](../../integrations/roxum-grpc/example/README.md) for all four
method forms and the [distribution guide](../../integrations/roxum-grpc/DISTRIBUTION.md)
for the generator and URL imports.

## API comparison

`roc bump` compares packages that both compile with the pinned compiler. The
published 0.2 platform and roxum-grpc 0.1.0 were written for the previous Roc
and do not compile with Roc 0.1, so their APIs cannot be compared with it. The
core minor bump reflects the changes above: the new handler variant, input
limits, stream completion, and the Roc 0.1 changes. The standalone Protobuf
wire package exposes no platform types and compiles with both: `roc bump`
requires a patch bump from 0.1.0, which 0.1.1 satisfies.
