HostTcp := [].{

	## What `Tcp.pool!` asks the host for. `tls` is 0 for none, 1 for the
	## system's CA certificates, 2 for those in `ca_file`. With `tls_later`
	## the handshake waits for `start_tls!`.
	PoolOptions : {
		host : Str,
		port : U16,
		tls : U8,
		ca_file : Str,
		tls_later : Bool,
		maximum_connections : U64,
		connect_timeout_milliseconds : U64,
		acquire_timeout_milliseconds : U64,
	}

	## What `Tcp.with_origin!` asks the host for: a connection to one origin
	## from the process's shared origin pools. `tls` is coded as in
	## `PoolOptions`. `timeout_milliseconds` bounds waiting for a free slot,
	## resolving, connecting, and the TLS handshake together. Without
	## `reuse_idle` the host opens a new connection.
	Origin : {
		host : Str,
		port : U16,
		tls : U8,
		ca_file : Str,
		reuse_idle : Bool,
		timeout_milliseconds : U64,
	}

	## - `Made`: the pool's handle.
	## - `CaUnavailable`: no CA certificates at the system location or in the file.
	## - `Invalid`: an empty host, port 0, or a connection limit outside 1 to 1024.
	## - `TooMany`: the process already has 32 pools.
	Made := [Made(U64), CaUnavailable, Invalid, TooMany]

	## - `Lent`: a connection's handle.
	## - `ResolveFailed`, `ResolveTimedOut`: the host name did not resolve.
	## - `ConnectFailed`, `ConnectTimedOut`: no address accepted a connection.
	## - `TlsFailed`: the TLS handshake failed, such as for an untrusted certificate.
	## - `Busy`: every connection stayed in use until the acquire timeout.
	Acquired := [Lent(U64), ResolveFailed, ResolveTimedOut, ConnectFailed, ConnectTimedOut, TlsFailed, Busy]

	## - `Unsent`: the write failed before the kernel accepted any byte, so
	##   the server received nothing of it.
	## - `Released`: the handle is not a connection lent to this code.
	## - `Refused`: `write_derived!` was given an invalid expression or secret.
	Sent := [Sent, Unsent, TimedOut, Closed, Failed, Released, Refused]

	## - `Overloaded`: the process's requests hold more memory than
	##   `Server.Limits.request_memory`, so nothing more is read.
	Received := [Bytes(List(U8)), TimedOut, Closed, Failed, Released, Overloaded]

	## - `TlsFailed`: the handshake failed, such as for an untrusted certificate.
	## - `Failed`: also when the pool has no TLS to start or it already started.
	Started := [Started, TlsFailed, TimedOut, Closed, Failed, Released]

	pool! : HostTcp.PoolOptions => HostTcp.Made
	acquire! : U64 => HostTcp.Acquired
	acquire_origin! : HostTcp.Origin => HostTcp.Acquired
	## A count of 0 with its `..._auto` set is `Server.Count.Auto`.
	configure_origins! : { connections_per_origin : U64, connections_auto : Bool, idle_connections : U64, idle_auto : Bool, idle_timeout_milliseconds : U64 } => Bool
	check_ca! : U8, Str => Bool
	release! : U64 => {}
	is_new! : U64 => Bool
	open_scope! : U64 => U64
	close_scope! : U64, U64 => {}
	scope_active! : U64, U64 => Bool
	discard! : U64 => {}
	write! : U64, List(U8), U64 => HostTcp.Sent
	write_derived! : U64, U64, List(U8), U64 => HostTcp.Sent
	read! : U64, U64, U64 => HostTcp.Received
	start_tls! : U64, U64 => HostTcp.Started
}
