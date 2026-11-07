# Databases

roxum talks to PostgreSQL through the [`roxum-postgres`](../../integrations/roxum-postgres/README.md) package. The
protocol is Roc; the host only keeps TCP connections in a pool and waits for the server. While one request waits
for a query, its thread serves other requests.

The code on this page follows the [DDD example](../../examples/ddd/README.md) and
the [layered-service test fixture](../../tests/layered-app/fixture/README.md); `zig build test-m9b-5` and `zig build
test-layered-app` run them against a throwaway PostgreSQL.

## Adding the package

```roc
app [program] {
	pf: platform "../../platform/main.roc",
	pg: "../../integrations/roxum-postgres/package/main.roc",
}

import pg.Postgres
```

## A pool in `init!`

Make one pool per database in `init!` and keep it in the model. Settings come from the [settings
files](deployment.md#settings); the password comes from a file of its own, which `Secret.from_file!` reads into the
host. Roc code holds a handle and never sees the password.

```roc
Settings : { database : { host : Str, port : U16, user : Str, name : Str, password_file : Str } }

init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	password = Secret.from_file!(settings.database.password_file).map_err(|_| StartupErr("cannot read the database password file"))?
	db = Postgres.pool!(
		Postgres.Config.{
			host: settings.database.host,
			port: settings.database.port,
			user: settings.database.user,
			database: settings.database.name,
			password: Postgres.Password.Secret(password),
		},
	).map_err(|_| StartupErr("invalid database settings"))?
	...
}
```

`Postgres.Config` also takes `tls`, `maximum_connections` (10), `connect_timeout_milliseconds` (10 s),
`acquire_timeout_milliseconds` (10 s), and `statement_timeout_milliseconds` (30 s); fields left out keep their
defaults.

- A process makes one pool, which all its threads share. With more `processes`, each makes its own, so the server
  sees up to processes × `maximum_connections` connections. Keep that below PostgreSQL's `max_connections`, minus
  what other clients need
- `tls: Tcp.Tls.On` verifies the server's certificate against the system's CA certificates, and the certificate must
  name `host`; `Tcp.Tls.OnWithCaFile(path)` uses a CA file instead (RDS and Cloud SQL publish theirs). TLS never
  falls back to plain text. Without CA certificates, `pool!` fails in `init!`
- Logins use SCRAM-SHA-256 or a plain-text password. MD5 passwords are not supported

## Migrations

`init!` runs in every process, and again in a process that restarts. Write migrations so that running them twice
changes nothing:

```roc
statements = [
	"CREATE TABLE IF NOT EXISTS products (sku TEXT PRIMARY KEY, name TEXT NOT NULL, stock BIGINT NOT NULL CHECK (stock >= 0))",
	"INSERT INTO products (sku, name, stock) VALUES ('tea', 'Green tea', 40) ON CONFLICT (sku) DO NOTHING",
]
```

For changes that are not idempotent, use a migration tool outside the server (run once per deployment), not `init!`.

## Queries

`query!` decodes rows into the type you ask for: a list of records whose fields match the columns by name.

```roc
User : { id : I64, name : Str, email : Try(Str, [Missing]) }

users : List(User)
users = Postgres.query!(model.db, "SELECT id, name, email FROM users WHERE age > $1", [Postgres.Param.Int(20)])?
```

- A NULL column is a missing field, so a field that may be NULL is `Try(T, [Missing])`
- A column the record has no field for is an error, which catches a misspelt alias
- Field types: `Str`, `Bool`, the integer types, `Dec` for `numeric`, `F32` / `F64`, `List(U8)` for `bytea`, and tags
  without payloads written in snake_case (`'read_only'` decodes as `ReadOnly`). Decode timestamps and other types
  as `Str`
- Parameters (`Postgres.Param.Int`, `Text`, `Float`, `Bool`, `Bytes`, `Null`) travel apart from the SQL, so a value
  never becomes SQL text. Build SQL from constants only

`execute!` returns how many rows a statement changed:

```roc
changed = Postgres.execute!(model.db, "UPDATE users SET email = $1 WHERE id = $2", [Postgres.Param.Text(email), Postgres.Param.Int(id)])?
```

Each `query!` and `execute!` borrows a connection for that one statement and returns it.

## Transactions

```roc
order = Postgres.transaction!(model.db, |tx| {
	product = Postgres.query!(tx, "SELECT ... FROM products WHERE sku = $1 FOR UPDATE", [Postgres.Param.Text(sku)])?
	_ = Postgres.execute!(tx, "UPDATE products SET stock = $1 WHERE sku = $2", [...])?
	Postgres.query!(tx, "INSERT INTO orders (...) VALUES (...) RETURNING id", [...])
})?
```

- `Ok` commits and `Err` rolls back, however the function ends, including through `?`
- The transaction keeps one connection until its function returns. Using `tx` after that is
  `PostgresTransactionEnded`
- `query!`, `execute!`, and `transaction!` take the pool or a transaction, so one repository function serves both.
  A transaction inside a transaction is a savepoint: an `Err` inside rolls back only the inner part
- `SELECT ... FOR UPDATE` locks the rows until the transaction ends, so concurrent requests that change the same row
  take turns. Choose this when a read-modify-write operation must serialize competing updates.
- `Postgres.transaction_with!(db, Postgres.TxOptions.{ isolation: Postgres.Isolation.Serializable }, ...)` sets the
  isolation level. A serialization failure (SQLSTATE `40001`) is returned, not retried: run the transaction again
  only when it has no effects outside the database
- An error that the function swallows instead of returning leaves PostgreSQL's transaction failed; every later
  statement in it fails (`25P02`) until the function returns
- A transaction holds its connection and its locks for as long as its function runs. Do not call slow outside
  services inside one

For a use case that spans multiple writes, keep the transaction boundary in
an infrastructure adapter and expose only the operations needed by the use case.
The [DDD users example](../../examples/ddd/README.md) performs one atomic write
per create operation and therefore calls its repository directly.

## Errors

A failed statement is `PostgresQueryFailed({ code, message, constraint })`. `code` is the SQLSTATE, for example:

| code | meaning | typical reply |
|---|---|---|
| `23505` | unique violation | 409 |
| `23503` | foreign key violation | 409 or 422 |
| `40001` | serialization failure | retry, or 409 |
| `57014` | statement timeout | 503 |

Other errors: `PostgresTimedOut`, `PostgresClosed`, `PostgresFailed` (the connection), `PostgresOverloaded` (the
process's requests hold more memory than `Server.Limits.request_memory`; answer 503), `PostgresLoginFailed(message)`,
`PostgresTlsFailed`, `PostgresTlsRefused`, `PostgresDecodeFailed(message)`, `PostgresTransactionEnded`, and the
`Tcp...` errors of making a connection (`TcpConnectFailed`, `TcpBusy` when the pool stayed full, ...).

Messages name the column or the constraint but never the values: PostgreSQL's `DETAIL` field, which often contains
values, is not read. In an adapter, map the database's errors to what the core understands (`Unavailable` in the
examples) and log which query failed.

## Connections and session state

- A connection goes back to the pool as it is. A setting changed with `SET` stays for the next request on that
  connection; use `SET LOCAL` inside a transaction instead, which ends with the transaction
- A connection left inside a transaction (a bare `BEGIN` through `execute!`) is closed instead of returned
- A connection the server closed while it sat idle is replaced before it is lent
- Each statement has `statement_timeout_milliseconds`: PostgreSQL's `statement_timeout`, and the host waits a second
  longer for the answer

## Testing

`tests/support/postgres_server.py` starts a throwaway PostgreSQL: the local binaries when `initdb` is installed,
otherwise Docker's `postgres:17`. It creates the roles `app` (SCRAM) and `clear` (plain-text password) and a database
`app`, with TLS on. The examples' runners use it; CI installs PostgreSQL for them.

## Not supported yet

- Queries checked at build time (a generator from SQL files, or a query builder); results are decoded at run time
- PostgreSQL 17's direct TLS (`sslnegotiation=direct`), `LISTEN` / `NOTIFY`, `COPY`, and a prepared-statement cache
