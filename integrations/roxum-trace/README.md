# roxum-trace

`roxum-trace` provides two middleware layers: `RequestId` sets each response's `x-request-id`, and `Trace` writes
one log line per request. Apply both with `Router.layer` so they also cover synthetic 400, 404, and 405 responses.

```roc
import trace.RequestId
import trace.Trace

routes =
	routes_without_tracing
		.layer(Trace.layer({}))
		.layer(RequestId.layer({}))
```

Both use the request's ID, `request.request_id`, which the host decides when the request head arrives, before any
Roc code runs. The host's own logs (`dbg`, crashes) name the request by the same ID. Where it comes from is set in
`listen`:

- `Server.RequestIdSource.Generate` (the default) gives every request a new ID of 32 lowercase hex digits. A
  client-chosen ID could collide with another request's ID in the logs.
- `Server.RequestIdSource.TrustIncoming` keeps a single incoming `x-request-id` of 1 to 128 visible ASCII bytes
  (`0x21`–`0x7E`) and generates one only when it is missing, invalid, or repeated. Use it only when every request
  arrives through a proxy that sets or replaces the field.

The request's `x-request-id` fields stay in `request.headers` as received; read the ID from `request.request_id`.

## RequestId

- `RequestId.layer({})` sets the request's ID as the `x-request-id` of both successful and error replies, replacing
  any `x-request-id` the handler added, so the response carries exactly one.
- Leave it out to keep the ID out of responses; the host does not add the field itself.

## Trace

Each request writes one `Info` line:

```text
[INFO] GET /users/1 200 1.250ms request_id=4bf92f3577b34da6a3ce929d0e0e4736
```

- Fields are the method, the request path before percent-decoding, the response status, and the duration.
- The status is the one in the `Reply` the inner handler returned. The host can still send a different response
  afterwards, and the line does not show it: a `503` when the process already writes `Server.Limits.maximum_streams`
  streams, or a `500` when the reply cannot be encoded (for example, an invalid header value).
- Requests the host answers before any Roc code runs get no line, such as a malformed request (`400`), a timeout
  (`408`), a body over the limit (`413`), or a full body buffer (`503`).
- The duration is measured with the platform's monotonic clock and truncated to microseconds. It covers the handler,
  not writing the response.
- `request_id=` is the request's ID, the same with or without `RequestId`.
- Spaces and control bytes in the path and the ID are percent-encoded so that each request stays on one line.

The format is a plain log line, not a stable machine-readable schema. OpenTelemetry support is deferred; see
[observability guide](../../docs/guides/observability.md).
