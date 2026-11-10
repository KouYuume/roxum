# Observability

roxum names every request by an ID that its own logs and the app share, can write an access log, and can serve
Prometheus metrics and health checks on an admin port of their own.

## Request IDs

The host decides each request's ID when the request head arrives, before any app code runs, and the app reads it as
`request.request_id`. The host's own lines (`dbg`, crashes, the access log) name the request by the same ID, so a
request the host answered without running the app has one too.

Where the ID comes from is set in `listen`:

```roc
listen: {
    endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((0, 0, 0, 0)), port: 8080 }),
    timeouts: Server.Timeouts.defaults,
    limits: Server.Limits.defaults,
    request_id: Server.RequestIdSource.TrustIncoming,   # leave out for Generate
}
```

- `Server.RequestIdSource.Generate`, the default, gives every request a new ID: 32 lowercase hex digits from 128
  random bits, the form of a W3C Trace Context trace ID.
- `Server.RequestIdSource.TrustIncoming` keeps the request's `X-Request-Id` when it has exactly one and it is 1 to 128
  visible ASCII bytes, and generates an ID otherwise. Use it only when every request arrives through a proxy that sets
  or replaces `X-Request-Id`; a client-chosen ID could collide with another request's in the logs.

The request's own `X-Request-Id` fields stay in `request.headers` as received. To send the ID back to the client,
apply `RequestId.layer({})` from `roxum-trace`, which sets it as the response's `X-Request-Id`; the host does not add
the field itself.

## Access log

Turn it on in `listen`:

```roc
listen: {
    ...
    access_log: Server.AccessLog.JsonLines,             # leave out for Off
}
```

Each worker then writes one JSON line on stderr per response:

```json
{"time":"2026-10-23T07:12:03.123Z","method":"GET","route":"/users/{id}","status":200,"outcome":"handled","body_bytes":1234,"duration_us":1830,"queue_us":45,"pid":4123,"request_id":"9f86d081884c7d659a2feaa0c55ad015"}
```

| Field | Meaning |
|---|---|
| `time` | When the response was done, in RFC 3339 UTC to the millisecond |
| `method` | The request method; left out when the host answered before reading a request line |
| `route` | The route pattern that answered, with any nest prefix, such as `/api/{tenant}/users/{id}`, or `fallback` for a custom fallback; left out for a 405, the default 404, and answers the app did not give |
| `path` | The request path without its query; only with `Server.AccessLog.JsonLinesWithPath` |
| `status` | The status code sent |
| `outcome` | Why the response is what it is; see below |
| `body_bytes` | Response body bytes, without the head; for a stream, every chunk; none for `HEAD` |
| `duration_us` | Microseconds from the complete request head to the response being done |
| `queue_us` | Microseconds the request waited for one of the worker's Roc threads; left out when the host refused it while it waited |
| `pid` | The worker process, as in `dbg` and crash lines |
| `request_id` | The request's ID (see above) |

Bodies, headers, cookies, query strings, and the client's address are never written. The path is left out by default
because some apps put personal data or tokens in paths; the route pattern carries none and has few values, so it is
the field to group and count by.

The `outcome` tells apart responses with the same status:

| Outcome | Status | Meaning |
|---|---|---|
| `handled` | any | The app answered, and the whole response was written |
| `crashed` | 500 | The app's code crashed while handling the request |
| `bad_request` | 400, 414, 417, 431, 501, 505 | The host refused a malformed or unsupported request |
| `timeout` | 408 | The request head or body did not arrive in time |
| `too_large` | 413 | The request body was over the limit |
| `queue_full` | 503 | The worker's queue was full (`Server.Limits.maximum_queued_requests`) |
| `queue_timeout` | 503 | The request waited past `Server.Limits.queue_timeout_milliseconds` |
| `in_progress_full` | 503 | The worker had `Server.Limits.maximum_requests_in_progress` requests |
| `overloaded` | 503 | An overloaded worker answered a new connection without reading it |
| `body_budget` | 503 | The request bodies the worker was receiving filled its buffer |
| `stream_limit` | 503 | The worker already wrote `Server.Limits.maximum_streams` streams |
| `encode_failed` | 500 | The app's reply could not be sent, such as an invalid header value |
| `client_closed` | any | The connection closed or failed before the whole response was written |
| `drained` | any | The worker stopped while the app wrote a body marked `ends_on_drain`; the body ended cleanly there |

The path is cut at 512 bytes and the route at 256, so a line stays well under 4 KiB. Lines up to `PIPE_BUF` bytes
(4096 on Linux, 512 on macOS) are written whole even when several workers share stderr.

### A slow stderr

A worker hands its lines to a thread of its own and never waits for stderr: in a container stderr is a pipe to the
runtime, and a request held by a slow log reader would hold every request of the worker. When stderr falls far behind,
the worker drops lines rather than wait. A draining worker writes the lines it holds before it exits, within the drain
timeout.

### When to use it

A reverse proxy or load balancer often writes its own access log, so roxum's is off by default. Turn it on for what
only roxum knows: the route pattern, the 503s and 500s it gave without running the app, and the time requests waited
for the Roc thread. `roxum-trace`'s `Trace` writes a plain-text line per request from inside the app instead; it
cannot see the host's own answers.

## Metrics and health checks

Enable metrics in `listen` with a TCP endpoint or a separate filesystem Unix socket (see [listener endpoints](deployment.md#listener-endpoints)):

```roc
listen: {
    ...
    metrics: Server.Metrics.Listen(Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 9090 })),   # leave out for Off
}
```

Use `127.0.0.1` when an agent on the same machine reads it, and `0.0.0.0` when Prometheus reads it across the
network, as in Kubernetes. The metrics name the app's routes and its load, so keep the port off the public network.

The supervisor answers the admin port, not the workers, so it answers while every worker is busy:

| Path | Answer |
|---|---|
| `/metrics` | Every metric below, in the Prometheus text format |
| `/live` | `200` while the supervisor runs |
| `/ready` | `200` while at least one worker is up and the server is not draining; `503` otherwise |

`/live` and `/ready` do not check the app's own dependencies, such as its database; write a route for that. Because
the supervisor answers `/live`, it stays `200` even when every worker is stuck in a long computation; watch
`roxum_queued_requests` to catch that. In Kubernetes, point the liveness probe at `/live` and the readiness probe at
`/ready`:

```yaml
livenessProbe:
  httpGet: { path: /live, port: 9090 }
readinessProbe:
  httpGet: { path: /ready, port: 9090 }
```

### What is counted

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `roxum_http_requests_total` | counter | `route`, `method`, `status`, `outcome` | Responses, one for each access log line |
| `roxum_http_request_duration_seconds` | histogram | `route` | From the complete request head to the response being done |
| `roxum_http_response_body_bytes_total` | counter | `route` | Response body bytes |
| `roxum_queue_wait_seconds` | histogram | | Time requests waited for one of a worker's Roc threads |
| `roxum_tcp_pool_wait_seconds` | histogram | `origin` | Time to get a connection from an outbound pool (`Tcp`, `HttpClient`, `Postgres`) |
| `roxum_tcp_pool_hold_seconds` | histogram | `origin` | Time a connection was lent before it came back |
| `roxum_queued_requests` | gauge | `worker` | Requests waiting for one of the worker's Roc threads |
| `roxum_requests_in_progress` | gauge | `worker` | Requests the worker started and has not finished, most waiting on a database or an outside API |
| `roxum_connections` | gauge | `worker` | Connections the worker holds |
| `roxum_streams` | gauge | `worker` | Streamed responses the worker is writing |
| `roxum_request_memory_bytes` | gauge | `worker` | Memory the worker's requests hold, against `Server.Limits.request_memory` |
| `roxum_worker_restarts_total` | counter | | Workers the supervisor started again after one ended |
| `roxum_access_log_dropped_total` | counter | | Access log lines dropped because stderr fell behind |
| `roxum_metrics_dropped_total` | counter | | Requests not counted by route because too many label combinations were seen |

- `route` is the route pattern, as in the access log; `""` for a 405, the default 404, and answers the app did not
  give. An app with more than 512 route patterns gets `""` for all of them, with a warning at startup.
- `status` is the exact code, and `outcome` is as in the access log.
- `origin` is the pool's `host:port`. Past 64 origins, in the order first used, the rest are counted as `other`.
- `worker` is the worker's number, from `0`. A worker is one of the processes the supervisor runs
  (`Server.ListenOptions.processes`, 1 by default); its gauges add up all its threads. A restarted worker keeps its
  number, so restarts do not add series.
- Counters and histograms add up every worker's counts. They live in memory the workers share, so a worker that
  crashes keeps what it counted.
- Histogram buckets are the Prometheus defaults: 5 ms to 10 s. For faster requests, read `duration_us` in the access
  log.
- Label combinations appear once counted.
