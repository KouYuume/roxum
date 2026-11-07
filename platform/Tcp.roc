import HostTcp
import Secret
import Server

## Outbound TCP connections, with or without TLS, for clients written in Roc
## such as a PostgreSQL or HTTP client. Apps use those clients rather than
## `Tcp` itself.
##
## Make a pool for each server in `init!` and keep it in the model; the host
## keeps the connections, so they outlive the request that opened them.
## Borrow a connection only inside `Tcp.with!`, which returns it however the
## function ends.
##
## A read or write that has to wait suspends only the current request; the
## thread serves other requests meanwhile.
Tcp := [].{

	## The pool's handle. The host keeps its connections.
	Pool :: U64

	## A connection lent by `Tcp.with!`, valid only inside its function.
	Connection :: U64

	## A protocol scope inside a borrowed connection. Each nested scope has
	## its own lifetime, independent of the connection's outer lease.
	Scope :: { connection : U64, id : U64 }

	## Keeps a scope active only while `run!` executes. Returning its value
	## is allowed, but `scope_active!` will then be false.
	## Returns `TcpFailed` if the lease ended or a scope cannot be allocated.
	scoped! = |Tcp.Connection.(connection), run!| {
		id = HostTcp.open_scope!(connection)
		if id == 0 {
			return Err(TcpFailed)
		}
		result = run!(Tcp.Scope.({ connection, id }))
		HostTcp.close_scope!(connection, id)
		result
	}

	scope_active! : Tcp.Scope => Bool
	scope_active! = |Tcp.Scope.({ connection, id })| HostTcp.scope_active!(connection, id)

	## `On` verifies the server with the system's CA certificates; `OnWithCaFile`
	## with those in the PEM file at an absolute path. The certificate must
	## name `host`.
	Tls := [Off, On, OnWithCaFile(Str)]

	PoolOptions := {
		host : Str,
		port : U16,
		tls : Tcp.Tls ?? Tcp.Tls.Off,

		## TLS that the client starts with `start_tls!` after a plain-text
		## exchange of its own, such as PostgreSQL's SSLRequest. Only one of
		## `tls` and `tls_later` may be on.
		tls_later : Tcp.Tls ?? Tcp.Tls.Off,

		## Connections open at once, from 1 to 1024. A request that finds all of
		## them in use waits for one up to `acquire_timeout_milliseconds`.
		maximum_connections : U64 ?? 10,

		## Resolving the host name and connecting, including the TLS handshake.
		connect_timeout_milliseconds : U64 ?? 10_000,
		acquire_timeout_milliseconds : U64 ?? 10_000,
	}

	## Makes a pool for one server. Call it in `init!`; with TLS it fails when
	## no CA certificates can be loaded.
	pool! : Tcp.PoolOptions => Try(Tcp.Pool, [TcpCaUnavailable, TcpInvalidPool, TcpTooManyPools])
	pool! = |options| {
		now = tls_code(options.tls)
		later = tls_code(options.tls_later)
		if now.0 != 0 and later.0 != 0 {
			return Err(TcpInvalidPool)
		}
		(tls, ca_file) = if later.0 != 0 {
			later
		} else {
			now
		}
		made = HostTcp.pool!({
			host: options.host,
			port: options.port,
			tls,
			ca_file,
			tls_later: later.0 != 0,
			maximum_connections: options.maximum_connections,
			connect_timeout_milliseconds: options.connect_timeout_milliseconds,
			acquire_timeout_milliseconds: options.acquire_timeout_milliseconds,
		})
		match made {
			Made(handle) => Ok(Tcp.Pool.(handle))
			CaUnavailable => Err(TcpCaUnavailable)
			Invalid => Err(TcpInvalidPool)
			TooMany => Err(TcpTooManyPools)
		}
	}

	## Runs `use!` with a connection from the pool: an idle one, or a new one.
	## When `use!` returns, `Ok` or `Err`, the connection goes back to the pool,
	## unless a read or write on it failed or `discard!` marked it; then it is
	## closed. A connection that the server closed while it sat idle is
	## replaced before it is lent.
	with! : Tcp.Pool, (Tcp.Connection => Try(a, [TcpResolveFailed, TcpResolveTimedOut, TcpConnectFailed, TcpConnectTimedOut, TcpTlsFailed, TcpBusy, ..errors])) => Try(a, [TcpResolveFailed, TcpResolveTimedOut, TcpConnectFailed, TcpConnectTimedOut, TcpTlsFailed, TcpBusy, ..errors])
	with! = |Tcp.Pool.(pool), use!| {
		connection = match HostTcp.acquire!(pool) {
			Lent(handle) => handle
			ResolveFailed => return Err(TcpResolveFailed)
			ResolveTimedOut => return Err(TcpResolveTimedOut)
			ConnectFailed => return Err(TcpConnectFailed)
			ConnectTimedOut => return Err(TcpConnectTimedOut)
			TlsFailed => return Err(TcpTlsFailed)
			Busy => return Err(TcpBusy)
		}
		result = use!(Tcp.Connection.(connection))
		HostTcp.release!(connection)
		result
	}

	## Where `with_origin!` connects: a host, a port, and the TLS to use.
	## With `reuse_idle` off, the connection is a new one even when an idle
	## one is available, as when retrying after an idle one failed.
	Origin := {
		host : Str,
		port : U16,
		tls : Tcp.Tls,
		reuse_idle : Bool ?? Bool.True,
	}

	## Runs `use!` with a connection to `origin` from the process's shared
	## origin pools, for clients such as an HTTP client that reach servers
	## known only at run time. The host makes a pool for an origin when it is
	## first used and drops it when it has no connections left.
	##
	## - At most 64 connections per origin are in use at once; a request that
	##   finds them all in use waits for one
	## - Idle connections close after 90 seconds, and at most 100 stay idle
	##   across all origins; beyond that the oldest closes
	##
	## `timeout_milliseconds` bounds waiting for a connection, resolving,
	## connecting, and the TLS handshake together. `TcpBusy` means every
	## connection stayed in use until then. As with `with!`, the connection
	## goes back when `use!` returns, unless a read or write failed or
	## `discard!` marked it.
	with_origin! : Tcp.Origin, U64, (Tcp.Connection => Try(a, [TcpResolveFailed, TcpResolveTimedOut, TcpConnectFailed, TcpConnectTimedOut, TcpTlsFailed, TcpBusy, ..errors])) => Try(a, [TcpResolveFailed, TcpResolveTimedOut, TcpConnectFailed, TcpConnectTimedOut, TcpTlsFailed, TcpBusy, ..errors])
	with_origin! = |Tcp.Origin.({ host, port, tls, reuse_idle }), timeout_milliseconds, use!| {
		(code, ca_file) = tls_code(tls)
		connection = match HostTcp.acquire_origin!({ host, port, tls: code, ca_file, reuse_idle, timeout_milliseconds }) {
			Lent(handle) => handle
			ResolveFailed => return Err(TcpResolveFailed)
			ResolveTimedOut => return Err(TcpResolveTimedOut)
			ConnectFailed => return Err(TcpConnectFailed)
			ConnectTimedOut => return Err(TcpConnectTimedOut)
			TlsFailed => return Err(TcpTlsFailed)
			Busy => return Err(TcpBusy)
		}
		result = use!(Tcp.Connection.(connection))
		HostTcp.release!(connection)
		result
	}

	## The process-wide limits of the origin pools `with_origin!` uses:
	## connections in use at once per origin (`Auto`: 64 for each thread;
	## `Fixed` takes 1 to 1024 for each thread), idle connections kept across
	## all origins (`Auto`: 100 for each thread; `Fixed` takes 0 to 65536 for
	## each thread), and how long one may stay idle (1 ms to one hour).
	OriginLimits := {
		connections_per_origin : Server.Count ?? Server.Count.Auto,
		idle_connections : Server.Count ?? Server.Count.Auto,
		idle_timeout_milliseconds : U64 ?? 90_000,
	}

	## Sets the origin pools' limits for this process. Call it in `init!`,
	## before the first `with_origin!`; later, or with a limit outside its
	## range, it is `TcpInvalidOriginLimits`.
	configure_origins! : Tcp.OriginLimits => Try({}, [TcpInvalidOriginLimits])
	configure_origins! = |Tcp.OriginLimits.({ connections_per_origin, idle_connections, idle_timeout_milliseconds })| {
		(connections_auto, connections) = count_parts(connections_per_origin)
		(idle_auto, idle) = count_parts(idle_connections)
		if HostTcp.configure_origins!({ connections_per_origin: connections, connections_auto, idle_connections: idle, idle_auto, idle_timeout_milliseconds }) {
			Ok({})
		} else {
			Err(TcpInvalidOriginLimits)
		}
	}

	## Loads the CA certificates `tls` names, so that a client using
	## `with_origin!` can fail in `init!` when they are missing (D8).
	check_ca! : Tcp.Tls => Try({}, [TcpCaUnavailable])
	check_ca! = |tls| {
		(code, ca_file) = tls_code(tls)
		if code == 0 or HostTcp.check_ca!(code, ca_file) {
			Ok({})
		} else {
			Err(TcpCaUnavailable)
		}
	}

	## True when the pool opened this connection for the current `with!`, so a
	## client must start its protocol (log in) before using it.
	is_new! : Tcp.Connection => Bool
	is_new! = |Tcp.Connection.(connection)| HostTcp.is_new!(connection)

	## Closes the connection instead of returning it to the pool, for a client
	## that finds it in a state the next user must not inherit.
	discard! : Tcp.Connection => {}
	discard! = |Tcp.Connection.(connection)| HostTcp.discard!(connection)

	## Starts the pool's `tls_later` on the connection, verifying the server
	## as `tls` would. Call it once, after the client's own negotiation.
	start_tls! : Tcp.Connection, U64 => Try({}, [TcpTlsFailed, TcpTimedOut, TcpClosed, TcpFailed, TcpReleased])
	start_tls! = |Tcp.Connection.(connection), timeout_milliseconds|
		match HostTcp.start_tls!(connection, timeout_milliseconds) {
			Started => Ok({})
			TlsFailed => Err(TcpTlsFailed)
			TimedOut => Err(TcpTimedOut)
			Closed => Err(TcpClosed)
			Failed => Err(TcpFailed)
			Released => Err(TcpReleased)
		}

	## Sends all of `bytes`, waiting no longer than `timeout_milliseconds`.
	## `TcpUnsent` means the write failed before any byte left, so the server
	## received nothing of it. `TcpReleased` means the connection's `with!`
	## has already returned.
	write! : Tcp.Connection, List(U8), U64 => Try({}, [TcpUnsent, TcpTimedOut, TcpClosed, TcpFailed, TcpReleased])
	write! = |Tcp.Connection.(connection), bytes, timeout_milliseconds|
		sent(HostTcp.write!(connection, bytes, timeout_milliseconds))

	## Sends what `exprs` compute with `secret`, joined, without the bytes
	## passing through Roc (D14). Unlike `Secret.derive!`, the result may
	## contain the secret itself, as a plain password message does.
	write_derived! : Tcp.Connection, Secret, List(Secret.Expr), U64 => Try({}, [TcpUnsent, TcpTimedOut, TcpClosed, TcpFailed, TcpReleased, TcpSecretRefused])
	write_derived! = |Tcp.Connection.(connection), secret, exprs, timeout_milliseconds|
		match HostTcp.write_derived!(connection, Secret.handle(secret), Secret.encode(exprs), timeout_milliseconds) {
			Refused => Err(TcpSecretRefused)
			other => sent(other)
		}

	## The next bytes the server sent, at most `maximum_bytes` (capped at
	## 64 KiB), waiting no longer than `timeout_milliseconds`. `TcpClosed`
	## means the server ended the connection. `TcpOverloaded` means the
	## process's requests hold more memory than `Server.Limits.request_memory`:
	## nothing was read, and the connection is closed when `with!` returns.
	read! : Tcp.Connection, U64, U64 => Try(List(U8), [TcpTimedOut, TcpClosed, TcpFailed, TcpReleased, TcpOverloaded])
	read! = |Tcp.Connection.(connection), maximum_bytes, timeout_milliseconds|
		match HostTcp.read!(connection, maximum_bytes, timeout_milliseconds) {
			Bytes(bytes) => Ok(bytes)
			TimedOut => Err(TcpTimedOut)
			Closed => Err(TcpClosed)
			Failed => Err(TcpFailed)
			Released => Err(TcpReleased)
			Overloaded => Err(TcpOverloaded)
		}
}

count_parts : Server.Count -> (Bool, U64)
count_parts = |count|
	match count {
		Server.Count.Auto => (Bool.True, 0)
		Server.Count.Fixed(value) => (Bool.False, value)
	}

tls_code : Tcp.Tls -> (U8, Str)
tls_code = |setting|
	match setting {
		Off => (0, "")
		On => (1, "")
		OnWithCaFile(path) => (2, path)
	}

sent : HostTcp.Sent -> Try({}, [TcpUnsent, TcpTimedOut, TcpClosed, TcpFailed, TcpReleased])
sent = |result|
	match result {
		Sent => Ok({})
		Unsent => Err(TcpUnsent)
		TimedOut => Err(TcpTimedOut)
		Closed => Err(TcpClosed)
		Released => Err(TcpReleased)
		Failed | Refused => Err(TcpFailed)
	}
