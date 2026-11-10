# Deployment

roxum serves plain HTTP/1.1 over IPv4 or IPv6 TCP; it does not listen on a Unix domain socket. Run it behind a reverse proxy or
load balancer that terminates TLS (and HTTP/2 or HTTP/3 for clients), such as nginx, Caddy, or AWS Application Load
Balancer.

```text
client ──HTTPS / HTTP/2──> proxy / load balancer ──HTTP/1.1──> roxum
```

## What the proxy and roxum each do

| | in front of roxum | in roxum |
|---|---|---|
| TLS, HTTP/2 and HTTP/3 to clients | the proxy (roxum has neither) | — |
| Static files | the proxy or a CDN, for a site mostly made of them | `Files.serve` and `Reply.file`, for files the app's routes own or check access to ([Files](files.md)) |
| Compression | the proxy's `gzip` / `brotli`, for everything at once | `Compression.layer`, for the routes you choose, and precompressed `.br` / `.gz` files ([Files](files.md#compressing-responses)) |

Compress in one place: with both on, the proxy finds `content-encoding` already set and passes the body on, but
that is wasted work in roxum.

## Building for Linux

Linux builds are statically linked against musl, so the executable runs on any distribution and in minimal images.

```bash
zig build host -Droc-target=x64musl          # or arm64musl for Graviton and other arm64 machines
roc build --opt=speed --target=x64musl --output=app app.roc
```

Both commands cross-compile, so a Mac can build the Linux executable. `zig build hosts` builds every target at once.

A container needs nothing but the executable:

```dockerfile
FROM scratch
COPY app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
```

Listen on a fixed port and on `0.0.0.0` in `init!` when a load balancer on another machine connects. When the proxy
runs on the same machine, listen on `127.0.0.1` so the server is not reachable directly.

## Settings

Settings that differ between environments go in TOML files, not in arguments or environment variables. The
executable takes no arguments but `--debug`.

- `config/base.toml`, next to `app.roc`, holds what every environment shares. `import "config/base.toml"` compiles it
  into the program
- `config/local.toml`, read from the **working directory** at startup, holds what this environment changes. Tables
  merge key by key; any other value it names, arrays included, replaces the base value

```roc
import "config/base.toml" as base_text : Str
import pf.Config

Settings : { listen : { port : U16 }, database : { host : Str, port : U16 } }

## Decoded while compiling: a base that does not fit Settings stops the build.
base_settings : Settings
base_settings = Config.check_base(base_text)

init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	...
}
```

The server does not start when `config/local.toml` is missing, so a deployment that forgot it never runs on the
base settings alone. An empty file is fine. A key that `Settings` does not have, a value of the wrong type, or a
syntax error also stops the startup; the message names the file or the key's path (`config: database.port: expected
an integer, found a string`) but never the value. Leave a key out of both files only when its field is
`Try(T, [Missing])`. Tags are written in snake_case: `level = "read_only"` for `ReadOnly`.

Put the file at `config/local.toml` under the working directory of the process:

```dockerfile
FROM scratch
COPY app /app
WORKDIR /
ENTRYPOINT ["/app"]
```

```bash
docker run -v "$PWD/production.toml:/config/local.toml:ro" -p 8080:8080 app
```

On Kubernetes, mount a ConfigMap whose key is `local.toml` at `/config`.

Settings files hold no secrets. Read secrets in `init!` with `Secret.from_file!` from a file the runtime mounts
(a Kubernetes Secret, a Docker secret), or, when the runtime only injects environment variables, with
`Secret.from_env!`. The value stays in the host; Roc code holds a handle.

## Processes and threads

The executable starts a supervisor and one worker process. The process runs `init!` once and serves requests on
several threads, which share its `Model`, its database and HTTP connections, and its limits. One thread accepts
connections and hands each to the thread holding the fewest. A request crash stops only that request
([Crashes](#crashes)); a process that ends is restarted by the supervisor.

`threads` in `Server.ListenOptions` sets the threads of the process:

- Left out, or `Server.Threads.Auto`: one per CPU the process may use, from 1 to 256. On Linux the count also follows
  the cgroup v2 CPU limit (`cpu.max`), so a container given 2 CPUs on a 32-CPU machine runs 2 threads
- `Server.Threads.Fixed(n)`: exactly `n`, from 1 to 256

An app whose code puts a function in a `Box` runs on one thread per process for now: that part of Roc's runtime is not
yet safe on several threads. `Reply.stream` and `roxum-sse` do not. `Auto` then uses one thread and says so
on stderr, and `Fixed` above 1 stops startup; raise `processes` to use more CPUs.

`processes` (1 by default, 1 to 64) runs more processes, each with its own `init!`, `Model`, connections, and
limits, sharing only the listening socket. More processes keep a failure of the host itself in one from stopping the
others, at the cost of what they cannot share: each holds its own database connections and caches.

```roc
listen: {
	address: IpAddr.V4((0, 0, 0, 0)),
	port: 8080,
	timeouts: Server.Timeouts.defaults,
	limits: Server.Limits.defaults,
	threads: Server.Threads.Fixed(4),
}
```

The first process starts alone; the `processes` its `init!` returns holds until the server stops. A restarted process
whose `init!` returns another number, because `config/local.toml` changed, logs a warning and the number stays.

- cgroup v1, and containers that do not get their own cgroup namespace, are not read; set `Fixed(n)` there
- A process raises its file descriptor limit toward the hard limit at start, for its `maximum_connections`

## Stopping

On SIGTERM or SIGINT the server drains:

1. It stops accepting at once; connections no process has accepted yet are refused
2. It closes keep-alive connections waiting for their next request
3. Requests and streams in progress finish; each response says `Connection: close`
4. Once nothing is left it exits 0

`drain_timeout_milliseconds` in `Server.ListenOptions` (20 s by default, 1 ms to one hour) bounds the drain. Past it,
the server cuts what is left, logs how many connections it cut, and exits 1; so does a second SIGTERM or SIGINT, such
as Ctrl-C pressed twice. A handler that computes without end cannot be interrupted, so the timeout is what stops it.

Signal the supervisor (the process that prints the port); the worker processes take their orders from it. Sending SIGTERM to
the whole process group, as systemd does by default, works the same.

If the supervisor itself is killed (`kill -9`, the OOM killer), its processes notice, write a warning, drain in the same
way, and exit. Nothing restarts the server then, so run it under something that does: a container runtime or systemd.

- **Kubernetes**: the Pod gets SIGTERM while it is still being removed from the Service's endpoints, so a few
  requests may arrive after the server stopped accepting. Delay the signal with a `preStop` hook that sleeps longer
  than that removal takes, and keep `terminationGracePeriodSeconds` (30 s by default) above the sleep plus the drain
  timeout:

  ```yaml
  lifecycle:
    preStop:
      exec:
        command: ["sleep", "5"]
  terminationGracePeriodSeconds: 30
  ```

  An image without a `sleep` program (a static binary on `scratch`) can use Kubernetes' own `sleep` action instead,
  where the cluster's version offers it.

- **Docker**: `docker stop` kills after 10 s by default, shorter than the 20 s drain. Give it more time with
  `docker stop --time 25`, or `stop_grace_period: 25s` in Compose, or lower the drain timeout
- **systemd**: `TimeoutStopSec` (90 s by default) must exceed the drain timeout. Exit 0 counts as a clean stop
- **Load balancers**: stop sending traffic before the signal, as with Kubernetes; an AWS target group's
  deregistration delay plays the part of the `preStop` sleep

## Keep-alive and timeouts

A proxy reuses idle connections to roxum. If roxum closes an idle connection first, the proxy may send the next
request into a closed connection and return `502` to the client. **Set roxum's keep-alive timeout longer than the
proxy's idle timeout.**

| Proxy | Idle timeout (default) | roxum setting |
|---|---|---|
| AWS ALB | 60 s | 75 s |
| nginx upstream `keepalive_timeout` | 60 s | 75 s |
| Caddy `reverse_proxy` keep-alive | 2 min | 135 s |

```roc
init! = |{}| Ok({
	model: {},
	listen: {
		address: IpAddr.V4((0, 0, 0, 0)),
		port: 8080,
		timeouts: {
			..Server.Timeouts.defaults,
			keep_alive_idle_milliseconds: 75_000,
		},
		limits: Server.Limits.defaults,
	},
})
```

`Server.Timeouts` has five limits, in milliseconds; each must be at least 1:

| Field | Default | Limits |
|---|---|---|
| `initial_request_milliseconds` | 5,000 | the first byte of the first request on a connection |
| `keep_alive_idle_milliseconds` | 15,000 | the wait for the next request on an idle connection |
| `request_head_milliseconds` | 5,000 | the whole request head after its first byte |
| `request_body_milliseconds` | 30,000 | the whole request body read into memory; for a body read as a stream, each wait for bytes |
| `response_write_milliseconds` | 30,000 | the whole response; for a streamed response, the head and each chunk |

Timeouts are checked every 50 ms, so a connection closes up to 50 ms after its deadline. Request heads are limited
to 32 KiB.

A request body is received before the handler runs, under `Server.Limits.maximum_body_bytes` (2 MiB), unless the handler
is `Handler.streaming`, which reads it in parts under `maximum_streamed_body_bytes` (none); see
[Streaming](streaming.md#reading-a-large-request-body). A body over its limit is answered `413`, a late one `408`, and
malformed chunked framing `400`; a handler that takes its body whole does not run.

The host reads up to 64 KiB of a body before any Roc code runs ([Middleware](middleware.md#the-body)). When one process
already holds 64 MiB of such bodies still arriving, a further request with a body is answered `503`.

Set the proxy's body limit at or above the largest a route takes, such as an upload route's.

## Limits and overload

Under too much load a process refuses work with `503 Service Unavailable` and `Retry-After: 1` rather than making
clients wait without an answer. `Server.Limits` sets, per process (fields left out are `Server.Count.Auto`, which gives
each thread the number in the table; `Server.Count.Fixed(n)` sets the process's own):

| Field | `Auto`, per thread | Limits |
|---|---|---|
| `maximum_streams` | 64 | streamed responses written at once |
| `maximum_queued_requests` | 1,024 | requests read but not yet started |
| `queue_timeout_milliseconds` | 5,000 (a plain number, not per thread) | how long a request may wait to start |
| `maximum_requests_in_progress` | 1,024 | requests started and not finished, most of them waiting on a database or an outside API |
| `maximum_connections` | 4,096 | connections held at once; `Fixed` takes 1 to 65,536 for each thread |
| `request_memory` | `Server.MemoryLimit.Auto` | the memory the process's requests may hold; `Server.MemoryLimit.Bytes(n)` sets it |
| `maximum_body_bytes` | 2 MiB (a plain number, not per thread) | a body received whole before the handler |
| `maximum_streamed_body_bytes` | `Server.BodyLimit.Unlimited` | a body read by a `Handler.streaming` handler; `Server.BodyLimit.Bytes(n)` sets it |

```roc
limits: Server.Limits.{ maximum_requests_in_progress: Server.Count.Fixed(16_384), request_memory: Server.MemoryLimit.Bytes(4 * 1024 * 1024 * 1024) },
```

Connections are divided evenly among the threads, since a connection stays on the thread that accepted it; the other
limits count across the process.

- **A full queue, or too many requests in progress, or the requests' memory near its limit**: the process stops
  accepting, so new connections go to the other processes, if any, which share the listening socket. If it is still
  overloaded 50 ms later and connections are waiting, it takes them and answers `503`
- **A request that waited longer than `queue_timeout_milliseconds`** is answered `503` without running, even while
  its thread is still busy with a long computation
- **Over `request_memory`**: reads from outside fail, so a database or HTTP call in progress returns
  `PostgresOverloaded` or `HttpClientOverloaded`; answer `503`. The process logs that it refused reads
- **`maximum_connections` reached**: the keep-alive connection that has waited longest for its next request is closed
  to make room; its client only connects again. With none idle, new connections wait for a slot

`Server.MemoryLimit.Auto` counts the live values of the process's requests against the memory the server may use (on
Linux the cgroup's `memory.max`, otherwise the machine's), divided among the processes, less 192 MiB for each thread
for what is not request values: the thread's own memory, bodies arriving, waiting requests' stacks and buffers, and
outbound TLS sessions. It is at least 32 MiB for each thread. A request waiting on a database or an outside API costs
about 60 KiB outside its values, so raising `maximum_requests_in_progress` raises the memory the process needs by that
much per request.

Streams: when a process already writes `maximum_streams` streams, a handler that returns another stream is
answered `503` before its head is sent, and the stream never runs; the handler's own effects have already happened.
Responses that are not streams, and streams answering `HEAD`, do not count. Each refusal logs a warning with the
request. There is no limit on how long a stream runs: a client that stops reading is cut off by
`response_write_milliseconds`, which applies to each chunk.

## Client addresses behind a proxy

Behind a proxy, `request.remote_addr` is the proxy. The `roxum-proxy-headers` package reads `X-Forwarded-For` and
`X-Forwarded-Proto` only when the direct peer is a proxy you trust. From any other peer it removes every forwarding
field (`X-Forwarded-*`, `X-Real-IP`, `Forwarded`); after resolving a trusted chain it removes `X-Forwarded-For`, so
read the client address from `remote_addr`:

```roc
routes =
	app_routes
		.before_routing(ProxyHeaders.trust(["10.0.0.0/16"]))
```

List the addresses your proxies connect from. For AWS ALB, whose addresses change, list its subnets or the VPC CIDR.

## Proxy examples

nginx:

```nginx
upstream roxum {
    server 127.0.0.1:8080;
    keepalive 32;
    keepalive_timeout 60s;
}

server {
    listen 443 ssl;
    http2 on;
    client_max_body_size 2m;   # raise it where a route takes more

    location / {
        proxy_pass http://roxum;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy:

```caddyfile
example.com {
    reverse_proxy 127.0.0.1:8080 {
        transport http {
            keepalive 2m
        }
    }
}
```

AWS ALB: an HTTPS listener with an ACM certificate forwards to an HTTP target group on roxum's port. Give the health
check a route that answers `200` without touching dependencies.

## Logs

roxum writes logs to stderr, one line per write. A line up to `PIPE_BUF` bytes (512 on macOS, 4096 on Linux) cannot
interleave with another process's output, and the threads of one process write their lines whole. The optional access
log, one JSON line per response, is described in [Observability](observability.md):

```text
[INFO] quoted 2 x tea at 9.00
[dbg] pid=4312 GET /users/42 request_id=abc123: "loaded user"
Roc crashed: pid=4312 GET /users/42 request_id=abc123: index out of bounds
```

`dbg` output and crashes name the request: method, path without the query (which often carries tokens), process id,
the request's ID, and the `traceparent` the request arrived with. The ID is the `request_id` the app reads from
`Http.Request`, decided by the host before any app code runs: a new random ID for every request, or, with
`request_id: Server.RequestIdSource.TrustIncoming` in `listen`, the request's own `X-Request-Id` when it has one
valid field. Trust it only when a proxy you trust sets or replaces `X-Request-Id`. `traceparent` is the client's
value, so do not use it to correlate requests unless such a proxy sets it too. Control bytes in messages from `Log`, `dbg`,
`expect`, and `crash` are written as `\xNN`, so request data in a message cannot start a line of its own.

## Crashes

A `crash` in a handler, or a handler running out of memory, stops only that request. It is answered `500` and its
connection closes; outgoing connections it held (`Tcp`, `HttpClient`, `Postgres`) are closed rather than reused,
because what was half sent on them is unknown. A PostgreSQL transaction it had open is rolled back by the server when
the connection closes. Other requests, in the same process too, go on.

A crash in a handler that has already sent the head of a `Reply.stream` body closes only that connection: the body
stops where it was. A crash in `init!` ends the process. Every connection that
process holds, on all its threads, is reset, including idle keep-alive connections; the proxy answers `502` for
requests in flight. The supervisor restarts the process.

Return errors as `Err(reply)` rather than crashing: a crash skips the rest of the handler, so work it had done outside
roxum stays as it was.

## Debug mode

Start the executable with `--debug` during development:

```bash
./app --debug
```

The values a handler passes to `dbg` are then attached to the response as `X-Roxum-Dbg` fields (percent-encoded; at
most 16, and only as many as fit in the response head; `X-Roxum-Dbg-Truncated` counts the rest). A streaming response carries only the values from before
its head was sent. **Never use `--debug` in production**: it shows internal values to clients. roxum prints a warning
at start when it is on. Any other argument makes the executable exit with status 2.

## IP listener addresses

Import `pf.IpAddr` and set `Server.ListenOptions.address` to `IpAddr.V4((127, 0, 0, 1))` for IPv4 loopback or `IpAddr.V6((0, 0, 0, 0, 0, 0, 0, 1))` for IPv6 loopback. IPv6 groups are host-order `U16` values. Eight zero groups select all IPv6 interfaces. `Server.Metrics.Listen.address` uses the same type.

IPv6 listeners explicitly enable `IPV6_V6ONLY`: they do not accept IPv4-mapped connections. IPv4 listeners retain their existing behavior. One application listener selects one family; exposing both families requires a proxy or separate server instances. Scoped IPv6 listener addresses requiring an interface identifier are not supported by this API.

To migrate from the IPv4-only API, replace `Server.Ipv4Address.(a, b, c, d)` with `IpAddr.V4((a, b, c, d))` and import `pf.IpAddr`. Peer addresses preserve their family in `RemoteAddr.ip`, including for proxy trust checks. Outbound TCP already resolves both address families and tries addresses in resolver order under the connection deadline; this is not a parallel Happy Eyeballs implementation.
