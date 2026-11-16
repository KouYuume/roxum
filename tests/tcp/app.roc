app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Secret
import pf.IpAddr
import pf.Server
import pf.Tcp

## Talks to the line servers the test runs: `PING` gets `PONG`, `SLOW`
## gets `DONE` after 300 ms, `HANG` gets nothing, `CLOSE` closes, and any
## other line comes back after `ECHO `.
Settings : {
	echo_port : U16,
	tls_port : U16,
	closed_port : U16,
	ca_file : Str,
}

Model := {
	plain : Tcp.Pool,
	single : Tcp.Pool,
	tls : Tcp.Pool,
	later : Tcp.Pool,
	untrusted : Tcp.Pool,
	unresolvable : Tcp.Pool,
	refused : Tcp.Pool,
	secret : Secret,
}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	pool! = |options| Tcp.pool!(options).map_err(|_| StartupErr("pool"))
	model = {
		plain: pool!(Tcp.PoolOptions.{ host: "localhost", port: settings.echo_port, maximum_connections: 32 })?,
		single: pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.echo_port, maximum_connections: 1, acquire_timeout_milliseconds: 100 })?,
		tls: pool!(Tcp.PoolOptions.{ host: "localhost", port: settings.tls_port, tls: Tcp.Tls.OnWithCaFile(settings.ca_file) })?,
		later: pool!(Tcp.PoolOptions.{ host: "localhost", port: settings.echo_port, tls_later: Tcp.Tls.OnWithCaFile(settings.ca_file) })?,
		untrusted: pool!(Tcp.PoolOptions.{ host: "localhost", port: settings.tls_port, tls: Tcp.Tls.On })?,
		unresolvable: pool!(Tcp.PoolOptions.{ host: "name-that-does-not-exist.invalid", port: 80 })?,
		refused: pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.closed_port })?,
		secret: Secret.from_env!("ROXUM_TEST_SECRET").map_err(|_| StartupErr("secret"))?,
	}
	Ok({
		model,
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/fast", MethodRouter.get(Handler.static(|{}| Reply.text("fast\n"))))
		.route("/line/{pool}/{line}", MethodRouter.get(Handler.effectful(line!)))
		.route("/new", MethodRouter.get(Handler.effectful(new!)))
		.route("/discard", MethodRouter.get(Handler.effectful(discard!)))
		.route("/fail-after-ping", MethodRouter.get(Handler.effectful(fail_after_ping!)))
		.route("/crash-in-with", MethodRouter.get(Handler.effectful(crash_in_with!)))
		.route("/secret", MethodRouter.get(Handler.effectful(secret!)))
		.route("/start-tls", MethodRouter.get(Handler.effectful(start_tls!)))

## Sends `line` on a connection from the named pool and replies with the
## server's answer, or with the error's name.
line! : Model, RouteContext({}) => Try(Reply, Reply)
line! = |model, context| {
	pool = match param(context, "pool") {
		"plain" => model.plain
		"single" => model.single
		"tls" => model.tls
		"untrusted" => model.untrusted
		"unresolvable" => model.unresolvable
		_ => model.refused
	}
	text = param(context, "line")
	answer = Tcp.with!(pool, |connection| exchange!(connection, text))
	Ok(Reply.text("${describe(answer)}\n"))
}

exchange! : Tcp.Connection, Str => Try(Str, _)
exchange! = |connection, text| {
	Tcp.write!(connection, "${text}\n".to_utf8(), 1_000)?
	bytes = Tcp.read!(connection, 1024, 1_000)?
	Ok(Str.from_utf8(bytes) ?? "?")
}

## Whether the pool opened the connection for this request.
new! : Model, RouteContext({}) => Try(Reply, Reply)
new! = |model, _context| {
	answer = Tcp.with!(model.plain, |connection| Ok(if Tcp.is_new!(connection) { "new" } else { "reused" }))
	Ok(Reply.text("${describe(answer)}\n"))
}

## A successful exchange whose connection the client marks unusable.
discard! : Model, RouteContext({}) => Try(Reply, Reply)
discard! = |model, _context| {
	answer = Tcp.with!(
		model.single,
		|connection| {
			reply = exchange!(connection, "PING")?
			Tcp.discard!(connection)
			Ok(reply)
		},
	)
	Ok(Reply.text("${describe(answer)}\n"))
}

## An error from the client's own logic: the connection itself is fine and
## goes back to the pool.
fail_after_ping! : Model, RouteContext({}) => Try(Reply, Reply)
fail_after_ping! = |model, _context| {
	answer = Tcp.with!(
		model.single,
		|connection| {
			_ = exchange!(connection, "PING")?
			Err(ClientRefused)
		},
	)
	Ok(Reply.text("${describe(answer)}\n"))
}

## A crash while the connection is lent: only the request stops, and the
## host closes the connection, whose state is unknown.
crash_in_with! : Model, RouteContext({}) => Try(Reply, Reply)
crash_in_with! = |model, _context| {
	answer = Tcp.with!(
		model.single,
		|connection| {
			_ = exchange!(connection, "PING")?
			crash "tcp test crash"
		},
	)
	Ok(Reply.text("${describe(answer)}\n"))
}

## Asks the server for TLS in plain text, as PostgreSQL's SSLRequest does,
## then talks over TLS. A reused connection is already encrypted.
start_tls! : Model, RouteContext({}) => Try(Reply, Reply)
start_tls! = |model, _context| {
	answer = Tcp.with!(
		model.later,
		|connection| {
			if Tcp.is_new!(connection) {
				go = exchange!(connection, "STARTTLS")?
				if go != "GO\n" {
					return Ok("no GO")
				}
				Tcp.start_tls!(connection, 1_000)?
			}
			exchange!(connection, "PING")
		},
	)
	Ok(Reply.text("${describe(answer)}\n"))
}

## Sends `SECRET <secret>` without the secret passing through Roc.
secret! : Model, RouteContext({}) => Try(Reply, Reply)
secret! = |model, _context| {
	answer = Tcp.with!(
		model.plain,
		|connection| {
			Tcp.write_derived!(connection, model.secret, [Concat(Bytes("SECRET ".to_utf8()), Concat(SecretValue, Bytes("\n".to_utf8())))], 1_000)?
			bytes = Tcp.read!(connection, 1024, 1_000)?
			Ok(Str.from_utf8(bytes) ?? "?")
		},
	)
	Ok(Reply.text("${describe(answer)}\n"))
}

describe = |answer|
	match answer {
		Ok(text) => Str.trim_end(text)
		Err(TcpTimedOut) => "TcpTimedOut"
		Err(TcpUnsent) => "TcpUnsent"
		Err(TcpOverloaded) => "TcpOverloaded"
		Err(TcpClosed) => "TcpClosed"
		Err(TcpFailed) => "TcpFailed"
		Err(TcpReleased) => "TcpReleased"
		Err(TcpBusy) => "TcpBusy"
		Err(TcpResolveFailed) => "TcpResolveFailed"
		Err(TcpResolveTimedOut) => "TcpResolveTimedOut"
		Err(TcpConnectFailed) => "TcpConnectFailed"
		Err(TcpConnectTimedOut) => "TcpConnectTimedOut"
		Err(TcpTlsFailed) => "TcpTlsFailed"
		Err(TcpSecretRefused) => "TcpSecretRefused"
		Err(ClientRefused) => "ClientRefused"
	}

param : RouteContext({}), Str -> Str
param = |context, name|
	match List.first(List.keep_if(context.path_params, |item| item.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
