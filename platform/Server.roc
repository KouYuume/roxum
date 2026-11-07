Server :: [].{
	## An IPv4 address, such as `(127, 0, 0, 1)` or `(0, 0, 0, 0)` for all
	## interfaces.
	Ipv4Address := (U8, U8, U8, U8)

	## Connection time limits in milliseconds. Every value must be at least 1;
	## the host refuses to start otherwise. Behind a load balancer, set
	## `keep_alive_idle_milliseconds` longer than the balancer's idle timeout
	## (60 s by default on AWS ALB) so the balancer never reuses a connection
	## roxum has just closed.
	Timeouts := {
		## Time to receive the first byte of the first request on a connection.
		initial_request_milliseconds : U64,
		## Time an idle keep-alive connection waits for the next request.
		keep_alive_idle_milliseconds : U64,
		## Time to receive a whole request head after its first byte.
		request_head_milliseconds : U64,
		## Time to receive a whole request body.
		request_body_milliseconds : U64,
		## Time to write a whole response, or, for a streamed response, each of
		## its parts: the head and every chunk get this long, so a stream may
		## run longer in total while the client keeps reading.
		response_write_milliseconds : U64,
	}.{
		## 5 s for the first request and each request head, 15 s keep-alive idle,
		## and 30 s for each request body and response write.
		defaults : Server.Timeouts
		defaults = {
			initial_request_milliseconds: 5_000,
			keep_alive_idle_milliseconds: 15_000,
			request_head_milliseconds: 5_000,
			request_body_milliseconds: 30_000,
			response_write_milliseconds: 30_000,
		}
	}

	## How much memory the requests of one process may hold at once: their
	## live values, including those of requests waiting on a database or an
	## outside API. `Auto` takes the memory the server may use (on Linux, a
	## cgroup's `memory.max` when lower) divided among the processes, less
	## 192 MiB for each thread. Near the limit the process stops admitting new
	## requests as when it is overloaded; over it, reads from outside fail
	## with `TcpOverloaded`, which clients report as their own `...Overloaded`.
	MemoryLimit := [Auto, Bytes(U64)]

	## A limit on a request body read as a stream: `Bytes(count)`, or
	## `Unlimited`.
	BodyLimit := [Unlimited, Bytes(U64)]

	## A limit for one process. `Auto` is the value given for each limit
	## below times the process's threads; `Fixed(count)` is the process's
	## own.
	Count := [Auto, Fixed(U64)]

	## What one process holds at once. Every value must be at least 1; the
	## host refuses to start otherwise.
	Limits := {
		## Streamed responses the process writes at once (`Auto`: 64 for each
		## thread). A handler that returns a stream past this limit is answered
		## `503 Service Unavailable` instead, and its stream never runs. Each
		## live stream keeps its own heap until it ends.
		maximum_streams : Server.Count ?? Server.Count.Auto,

		## Requests waiting to run (`Auto`: 1,024 for each thread). At this
		## many the process stops accepting and leaves new connections to the
		## other processes; when they are overloaded too, it answers new
		## connections `503 Service Unavailable` with `Retry-After`. A request
		## that waited longer than `queue_timeout_milliseconds` is answered 503
		## without running its handler.
		maximum_queued_requests : Server.Count ?? Server.Count.Auto,
		queue_timeout_milliseconds : U64 ?? 5_000,

		## Requests the process has started and not finished, most of them
		## waiting for a database or an outside API (`Auto`: 1,024 for each
		## thread). A request that would start past this many is answered 503,
		## and the process stops accepting as above.
		maximum_requests_in_progress : Server.Count ?? Server.Count.Auto,

		## Connections the process holds at once (`Auto`: 4,096 for each
		## thread; `Fixed` takes 1 to 65,536 for each thread). Past this many
		## the process stops accepting until one closes.
		maximum_connections : Server.Count ?? Server.Count.Auto,

		request_memory : Server.MemoryLimit ?? Server.MemoryLimit.Auto,

		## A request body received whole before the handler runs, as every handler
		## but `Handler.streaming` has it: past this many bytes the request is
		## answered `413 Content Too Large` and the handler does not run.
		maximum_body_bytes : U64 ?? 2_097_152,

		## A request body read by a `Handler.streaming` handler, which holds only
		## the part being read. `Unlimited` by default: the request's
		## memory limit still holds.
		##
		## A route's `BodyLimit` layers change either for its requests.
		maximum_streamed_body_bytes : Server.BodyLimit ?? Server.BodyLimit.Unlimited,
	}.{
		## Every limit `Auto`.
		defaults : Server.Limits
		defaults = {}
	}

	## How many threads one process runs requests on. `Auto` uses one per CPU
	## the process may use, counting a Linux cgroup's CPU limit (`cpu.max`),
	## up to 256. `Fixed(count)` takes 1 to 256.
	##
	## An app whose code puts a function in a `Box` links a part of Roc's
	## runtime that is not yet safe on several threads. It runs on one thread:
	## `Auto` then uses one and says so on stderr, and `Fixed` above 1 stops
	## startup. Raise `processes` instead.
	Threads := [Auto, Fixed(U16)]

	## Where a request's ID (`Http.Request.request_id`) comes from. The host
	## decides it when the request head arrives, so logs name the request
	## even when the host answers it without running the app. `Generate`
	## makes a new random 128-bit ID, 32 lowercase hex digits, for every
	## request. `TrustIncoming` keeps the ID in the request's `x-request-id`
	## field when there is exactly one and it is 1 to 128 visible ASCII
	## bytes, and generates one otherwise; use it only when every request
	## arrives through a proxy that sets or replaces `x-request-id`.
	RequestIdSource := [Generate, TrustIncoming]

	## Whether each process writes an access log: one JSON line on stderr per
	## response, including the ones the host answers without running the app
	## (`503` when overloaded, `400`, `408`, a crash's `500`). `Off` is the
	## default. A line names the time, method, route pattern, status, outcome,
	## body bytes, durations, process pid, and request ID; `JsonLinesWithPath`
	## adds the request path without its query. Bodies, headers, cookies, and
	## the client's address are never written.
	##
	## A process hands lines to a thread of its own, so a slow stderr never
	## holds a request; when stderr falls far behind, lines are dropped and
	## counted.
	AccessLog := [Off, JsonLines, JsonLinesWithPath]

	## Whether the server answers on an admin port of its own, apart from
	## the app's: `/metrics` in the Prometheus text format, `/ready`, and
	## `/live`. `Off` is the default. Give the admin port its own address,
	## such as `127.0.0.1` when an agent on the same machine reads it, or
	## `0.0.0.0` when Prometheus reads it across the network: the metrics name
	## the app's routes and its load.
	##
	## The supervisor answers it, so it answers even while every process is
	## busy. `/live` answers 200 while the supervisor runs. `/ready` answers
	## 200 while at least one process is up and the server is not draining,
	## and 503 otherwise. Neither checks the app's own dependencies; write a
	## route for that.
	Metrics := [Off, Listen({ address : Server.Ipv4Address, port : U16 })]

	## Where the server listens, its connection timeouts, its limits, and how
	## many threads and processes serve it. Returned by the app's `init!`;
	## `threads`, `processes`, `drain_timeout_milliseconds`, `request_id`,
	## `access_log`, and `metrics` may be left out. The processes (1 to 64, 1
	## by default) share nothing: each runs `init!` and has its own model,
	## pools, and limits. One process with a thread per CPU shares them all;
	## more processes keep a host failure in one from stopping the others.
	ListenOptions := {
		address : Server.Ipv4Address,
		port : U16,
		timeouts : Server.Timeouts,
		limits : Server.Limits,
		threads : Server.Threads ?? Server.Threads.Auto,
		processes : U16 ?? 1,
		## On SIGTERM or SIGINT the server stops accepting, closes idle
		## keep-alive connections, and lets requests and streams in progress
		## finish, each response closing its connection; it exits 0 once they
		## have. Past this many milliseconds (1 to 3,600,000; 20 s by default)
		## it cuts what is left and exits 1. A second signal does the same at
		## once.
		drain_timeout_milliseconds : U64 ?? 20_000,
		request_id : Server.RequestIdSource ?? Server.RequestIdSource.Generate,
		access_log : Server.AccessLog ?? Server.AccessLog.Off,
		metrics : Server.Metrics ?? Server.Metrics.Off,
	}
}
