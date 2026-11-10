app [program] {
	pf: platform "../../../platform/main.roc",
	pg: "../package/main.roc",
}

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
import pg.Postgres

## Exercises roxum-postgres against the server the test starts: queries
## into typed records, constraint errors, transactions and savepoints,
## timeouts, TLS, and the login methods.
Settings : { port : U16, ca_file : Str }

Model := {
	db : Postgres.Pool,
	quick : Postgres.Pool,
	secure : Postgres.Pool,
	untrusted : Postgres.Pool,
	wrong_password : Postgres.Pool,
	clear : Postgres.Pool,
}

User : { id : I64, name : Str, email : Try(Str, [Missing]) }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	secret! = |name| Secret.from_env!(name).map_err(|_| StartupErr("missing ${name}"))
	app_password = Postgres.Password.Secret(secret!("ROXUM_PG_APP_PASSWORD")?)
	pool! = |config|
		Postgres.pool!(config).map_err(
			|problem|
				match problem {
					PostgresCaUnavailable => StartupErr("pool: no CA certificates")
					PostgresInvalidConfig => StartupErr("pool: invalid configuration")
					PostgresTooManyPools => StartupErr("pool: too many pools")
				},
		)
	db = pool!(Postgres.Config.{ host: "127.0.0.1", port: settings.port, user: "app", database: "app", password: app_password, maximum_connections: 32 })?
	model = {
		db,
		quick: pool!(Postgres.Config.{ host: "127.0.0.1", port: settings.port, user: "app", database: "app", password: app_password, statement_timeout_milliseconds: 200 })?,
		secure: pool!(Postgres.Config.{ host: "localhost", port: settings.port, user: "app", database: "app", password: app_password, tls: Tcp.Tls.OnWithCaFile(settings.ca_file) })?,
		untrusted: pool!(Postgres.Config.{ host: "localhost", port: settings.port, user: "app", database: "app", password: app_password, tls: Tcp.Tls.On })?,
		wrong_password: pool!(Postgres.Config.{ host: "127.0.0.1", port: settings.port, user: "app", database: "app", password: Postgres.Password.Secret(secret!("ROXUM_PG_WRONG_PASSWORD")?) })?,
		clear: pool!(Postgres.Config.{ host: "127.0.0.1", port: settings.port, user: "clear", database: "app", password: Postgres.Password.Secret(secret!("ROXUM_PG_CLEAR_PASSWORD")?) })?,
	}
	# Migrations run in every worker, so they must be idempotent.
	migrated = Postgres.execute!(
		db,
		"CREATE TABLE IF NOT EXISTS users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE, email TEXT, balance BIGINT NOT NULL DEFAULT 100)",
		[],
	)
	match migrated {
		Ok(_) => {}
		Err(problem) => return Err(StartupErr("migration failed: ${describe(Err(problem))}"))
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
		.route("/users", MethodRouter.get(Handler.effectful(list_users!)))
		.route("/users/{name}", MethodRouter.post(Handler.effectful(create_user!)))
		.route("/users/{name}/email/{email}", MethodRouter.post(Handler.effectful(set_email!)))
		.route("/transfer/{from}/{to}/{amount}", MethodRouter.post(Handler.effectful(transfer!)))
		.route("/savepoint/{outer}/{inner}", MethodRouter.post(Handler.effectful(savepoint!)))
		.route("/escaped-transaction", MethodRouter.get(Handler.effectful(escaped_transaction!)))
		.route("/nested-scopes", MethodRouter.get(Handler.effectful(nested_scopes!)))
		.route("/aborted-transaction", MethodRouter.get(Handler.effectful(aborted_transaction!)))
		.route("/sleep", MethodRouter.get(Handler.effectful(sleep!)))
		.route("/statement-timeout", MethodRouter.get(Handler.effectful(statement_timeout!)))
		.route("/types", MethodRouter.get(Handler.effectful(types!)))
		.route("/decode-error", MethodRouter.get(Handler.effectful(decode_error!)))
		.route("/pool/{name}", MethodRouter.get(Handler.effectful(pool_check!)))
		.route("/left-in-transaction", MethodRouter.get(Handler.effectful(left_in_transaction!)))
		.route("/open-transactions", MethodRouter.get(Handler.effectful(open_transactions!)))

list_users! : Model, RouteContext({}) => Try(Reply, Reply)
list_users! = |model, _context| {
	users : List(User)
	users = Postgres.query!(model.db, "SELECT id, name, email FROM users ORDER BY id", []).map_err(failure)?
	lines = users.map(|user| "${user.id.to_str()} ${user.name} ${user.email ?? "-"}")
	Ok(Reply.text("${Str.join_with(lines, "\n")}\n"))
}

create_user! : Model, RouteContext({}) => Try(Reply, Reply)
create_user! = |model, context| {
	rows : List({ id : I64 })
	rows = Postgres.query!(model.db, "INSERT INTO users (name) VALUES ($1) RETURNING id", [Postgres.Param.Text(param(context, "name"))]).map_err(failure)?
	Ok(Reply.text("created ${(rows.first() ?? { id: 0 }).id.to_str()}\n").with_status(201))
}

set_email! : Model, RouteContext({}) => Try(Reply, Reply)
set_email! = |model, context| {
	changed = Postgres.execute!(model.db, "UPDATE users SET email = $1 WHERE name = $2", [Postgres.Param.Text(param(context, "email")), Postgres.Param.Text(param(context, "name"))]).map_err(failure)?
	Ok(Reply.text("changed ${changed.to_str()}\n"))
}

## Moves `amount` from one balance to another; a balance below zero rolls
## the transaction back.
transfer! : Model, RouteContext({}) => Try(Reply, Reply)
transfer! = |model, context| {
	amount = I64.from_str(param(context, "amount")) ?? 0
	moved = Postgres.transaction!(
		model.db,
		|tx| {
			_ = Postgres.execute!(tx, "UPDATE users SET balance = balance - $1 WHERE name = $2", [Postgres.Param.Int(amount), Postgres.Param.Text(param(context, "from"))])?
			_ = Postgres.execute!(tx, "UPDATE users SET balance = balance + $1 WHERE name = $2", [Postgres.Param.Int(amount), Postgres.Param.Text(param(context, "to"))])?
			balances : List({ balance : I64 })
			balances = Postgres.query!(tx, "SELECT balance FROM users WHERE name = $1", [Postgres.Param.Text(param(context, "from"))])?
			if (balances.first() ?? { balance: 0 }).balance < 0 {
				Err(InsufficientBalance)
			} else {
				Ok({})
			}
		},
	)
	match moved {
		Ok({}) => Ok(Reply.text("moved\n"))
		Err(InsufficientBalance) => Ok(Reply.text("insufficient\n").with_status(409))
		Err(other) => Err(failure(other))
	}
}

## Inserts `outer` in a transaction and `inner` in a savepoint that fails:
## only `outer` remains.
savepoint! : Model, RouteContext({}) => Try(Reply, Reply)
savepoint! = |model, context| {
	result = Postgres.transaction!(
		model.db,
		|tx| {
			_ = Postgres.execute!(tx, "INSERT INTO users (name) VALUES ($1)", [Postgres.Param.Text(param(context, "outer"))])?
			inner = Postgres.transaction!(
				tx,
				|inner_tx| {
					_ = Postgres.execute!(inner_tx, "INSERT INTO users (name) VALUES ($1)", [Postgres.Param.Text(param(context, "inner"))])?
					Err(InnerRefused)
				},
			)
			match inner {
				Err(InnerRefused) => Ok("inner rolled back")
				Ok({}) => Ok("inner kept")
				Err(other) => Err(other)
			}
		},
	)
	match result {
		Ok(text) => Ok(Reply.text("${text}\n"))
		Err(other) => Err(failure(other))
	}
}

## Keeps the transaction past its function; using it then is refused.
escaped_transaction! : Model, RouteContext({}) => Try(Reply, Reply)
escaped_transaction! = |model, _context| {
	escaped = Postgres.transaction!(model.db, |tx| Ok(tx)).map_err(failure)?
	rows : Try(List({ one : I32 }), _)
	rows = Postgres.query!(escaped, "SELECT 1 AS one", [])
	Ok(Reply.text("${describe(rows)}\n"))
}

## Both successful and rolled-back savepoints end their Tx lifetime. A new
## sibling scope must not revive an old handle, and the outer Tx stays valid.
nested_scopes! : Model, RouteContext({}) => Try(Reply, Reply)
nested_scopes! = |model, _context| {
	checked = Postgres.transaction!(
		model.db,
		|outer| {
			escaped = Postgres.transaction!(
				outer,
				|inner| {
					_ = Postgres.execute!(inner, "SELECT 1", [])?
					Ok(inner)
				},
			)?
			after = describe(Postgres.execute!(escaped, "SELECT 1", []))
			begin_after = describe(Postgres.transaction!(escaped, |_inner| Ok({})))
			sibling = Postgres.transaction!(
				outer,
				|inner| {
					_ = Postgres.execute!(inner, "SELECT 1", [])?
					Ok(describe(Postgres.execute!(escaped, "SELECT 1", [])))
				},
			)?
			failed = Postgres.transaction!(outer, |inner| Err(Kept(inner)))
			escaped_failed = match failed {
				Err(Kept(tx)) => tx
				_ => return Err(UnexpectedScopeResult)
			}
			after_failed = describe(Postgres.execute!(escaped_failed, "SELECT 1", []))
			_ = Postgres.execute!(outer, "SELECT 1", [])?
			Ok("${after};${begin_after};${sibling};${after_failed}")
		},
	).map_err(failure)?
	Ok(Reply.text(checked))
}

## Catching a SQL error cannot turn PostgreSQL's aborted transaction into
## a successful commit. The earlier write must also have rolled back.
aborted_transaction! : Model, RouteContext({}) => Try(Reply, Reply)
aborted_transaction! = |model, _context| {
	result = Postgres.transaction!(
		model.db,
		|tx| {
			_ = Postgres.execute!(tx, "INSERT INTO users(name) VALUES ('aborted')", [])?
			_ = Postgres.execute!(tx, "SELECT 1 / 0", [])
			Ok({})
		},
	)
	rows : List({ total : I64 })
	rows = Postgres.query!(model.db, "SELECT count(*) AS total FROM users WHERE name='aborted'", []).map_err(failure)?
	Ok(Reply.text("${describe(result)};${(rows.first() ?? { total: -1 }).total.to_str()}"))
}

## 300 ms in the server, so requests overlap only through fibers.
sleep! : Model, RouteContext({}) => Try(Reply, Reply)
sleep! = |model, _context| {
	rows : List({ done : Bool })
	rows = Postgres.query!(model.db, "SELECT pg_sleep(0.3) IS NOT NULL AS done", []).map_err(failure)?
	Ok(
		Reply.text(
			if rows == [{ done: Bool.True }] {
				"slept\n"
			} else {
				"?\n"
			},
		),
	)
}

statement_timeout! : Model, RouteContext({}) => Try(Reply, Reply)
statement_timeout! = |model, _context| {
	rows : Try(List({ done : Bool }), _)
	rows = Postgres.query!(model.quick, "SELECT pg_sleep(2) IS NOT NULL AS done", [])
	Ok(Reply.text("${describe(rows)}\n"))
}

## Values of several types, through parameters and back.
types! : Model, RouteContext({}) => Try(Reply, Reply)
types! = |model, _context| {
	rows : List({ small : I16, big : I64, price : Dec, ratio : F64, flag : Bool, data : List(U8), missing : Try(Str, [Missing]), state : [ReadOnly, ReadWrite] })
	rows = Postgres.query!(
		model.db,
		"SELECT $1::int2 AS small, $2::int8 AS big, $3::numeric AS price, $4::float8 AS ratio, $5::bool AS flag, $6::bytea AS data, NULL::text AS missing, 'read_only' AS state",
		[Postgres.Param.Int(-7), Postgres.Param.Int(9_007_199_254_740_993), Postgres.Param.Text("12.50"), Postgres.Param.Float(-F64.infinity), Postgres.Param.Bool(Bool.True), Postgres.Param.Bytes([0, 255, 16])],
	).map_err(failure)?
	ok = match rows {
		[row] => row.small == -7 and row.big == 9_007_199_254_740_993 and row.price == 12.5 and row.ratio == -F64.infinity and row.flag and row.data == [0, 255, 16] and row.missing == Err(Missing) and row.state == ReadOnly
		_ => Bool.False
	}
	Ok(
		Reply.text(
			if ok {
				"types ok\n"
			} else {
				"types wrong\n"
			},
		),
	)
}

decode_error! : Model, RouteContext({}) => Try(Reply, Reply)
decode_error! = |model, _context| {
	rows : Try(List({ age : I32 }), _)
	rows = Postgres.query!(model.db, "SELECT 'secret-value' AS age", [])
	Ok(Reply.text("${describe(rows)}\n"))
}

pool_check! : Model, RouteContext({}) => Try(Reply, Reply)
pool_check! = |model, context| {
	pool = match param(context, "name") {
		"secure" => model.secure
		"untrusted" => model.untrusted
		"wrong-password" => model.wrong_password
		_ => model.clear
	}
	rows : Try(List({ ssl : Bool }), _)
	rows = Postgres.query!(pool, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", [])
	text = match rows {
		Ok([{ ssl }]) => if ssl {
			"tls"
		} else {
			"plain"
		}
		other => describe(other)
	}
	Ok(Reply.text("${text}\n"))
}

## A statement that leaves a transaction open on a borrowed connection: the
## connection is closed instead of going back to the pool.
left_in_transaction! : Model, RouteContext({}) => Try(Reply, Reply)
left_in_transaction! = |model, _context| {
	_ = Postgres.execute!(model.quick, "BEGIN", []).map_err(failure)?
	Ok(Reply.text("began\n"))
}

## Connections of the app's role still inside a transaction.
open_transactions! : Model, RouteContext({}) => Try(Reply, Reply)
open_transactions! = |model, _context| {
	rows : List({ count : I64 })
	rows = Postgres.query!(model.db, "SELECT count(*) AS count FROM pg_stat_activity WHERE usename = 'app' AND state LIKE 'idle in transaction%'", []).map_err(failure)?
	Ok(Reply.text("${(rows.first() ?? { count: -1 }).count.to_str()}\n"))
}

describe = |result|
	match result {
		Ok(_) => "ok"
		Err(PostgresQueryFailed({ code, .. })) => "PostgresQueryFailed ${code}"
		Err(PostgresDecodeFailed(message)) => "PostgresDecodeFailed ${message}"
		Err(PostgresLoginFailed(_)) => "PostgresLoginFailed"
		Err(PostgresTlsFailed) => "PostgresTlsFailed"
		Err(PostgresTlsRefused) => "PostgresTlsRefused"
		Err(PostgresTransactionEnded) => "PostgresTransactionEnded"
		Err(PostgresTransactionRolledBack) => "PostgresTransactionRolledBack"
		Err(PostgresTimedOut) => "PostgresTimedOut"
		Err(PostgresClosed) => "PostgresClosed"
		Err(PostgresFailed) => "PostgresFailed"
		Err(PostgresProtocolFailed) => "PostgresProtocolFailed"
		Err(MissingRequiredField(name)) => "MissingRequiredField ${name}"
		Err(TcpResolveFailed) | Err(TcpResolveTimedOut) | Err(TcpConnectFailed) | Err(TcpConnectTimedOut) | Err(TcpTlsFailed) | Err(TcpBusy) => "connect failed"
		Err(_) => "other error"
	}

## Maps an error to a reply: 409 for a unique violation, 500 otherwise.
failure = |problem|
	match problem {
		PostgresQueryFailed({ code: "23505", .. }) => Reply.text("conflict\n").with_status(409)
		other => Reply.text("${describe(Err(other))}\n").with_status(500)
	}

param : RouteContext({}), Str -> Str
param = |context, name|
	match List.first(List.keep_if(context.path_params, |item| item.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
