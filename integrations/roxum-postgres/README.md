# roxum-postgres

A PostgreSQL client written in Roc over roxum's `Tcp`: the host keeps the connections in a pool, and the protocol
(login, queries, transactions) is Roc. Waiting for the server suspends only the request; its thread serves other
requests meanwhile.

```roc
app [program] {
	pf: platform "../../../platform/main.roc",
	pg: "../package/main.roc",
}

import pg.Postgres

# In init!: one pool per database, kept in the model.
db = Postgres.pool!(Postgres.Config.{
	host: "db.internal",
	user: "app",
	database: "app",
	password: Postgres.Password.Secret(password),   # a pf.Secret, from Secret.from_file!
	tls: Tcp.Tls.On,
})?

# In a handler:
User : { id : I64, name : Str, email : Try(Str, [Missing]) }

users : List(User)
users = Postgres.query!(model.db, "SELECT id, name, email FROM users WHERE age > $1", [Postgres.Param.Int(20)])?

changed = Postgres.execute!(model.db, "UPDATE users SET email = $1 WHERE id = $2", [Postgres.Param.Text(email), Postgres.Param.Int(id)])?
```

## Queries

- `query!` decodes the rows into the type the caller asks for: a list of records whose fields match the columns by
  name. A column the record has no field for is an error, so a misspelt alias is caught. A NULL column is a missing
  field: a field that may be NULL is `Try(T, [Missing])`
- Supported field types: `Str`, `Bool`, the integer types, `Dec` (for `numeric`), `F32` / `F64`, `List(U8)` (for
  `bytea`), and tags without payloads written in snake_case (`'read_only'` for `ReadOnly`). Other types, such as
  timestamps, decode as `Str`
- Parameters (`Postgres.Param.Int`, `Text`, `Float`, `Bool`, `Bytes`, `Null`) travel apart from the SQL in the
  extended query protocol, so values never become SQL text
- `execute!` returns the number of rows a statement changed
- Errors name the row and column but never the value. A failed statement is
  `PostgresQueryFailed({ code, message, constraint })`, where `code` is the SQLSTATE (`23505` for a unique
  violation)

## Transactions

```roc
order = Postgres.transaction!(model.db, |tx| {
	_ = Postgres.execute!(tx, "UPDATE stock SET count = count - 1 WHERE sku = $1", [Postgres.Param.Text(sku)])?
	rows : List({ id : I64 })
	rows = Postgres.query!(tx, "INSERT INTO orders (sku) VALUES ($1) RETURNING id", [Postgres.Param.Text(sku)])?
	Ok(rows)
})?
```

- `Ok` commits and `Err` rolls back, however the function ends. The transaction keeps one connection
- `query!`, `execute!`, and `transaction!` take the pool or a transaction alike, so a repository function can run
  on either
- A transaction inside a transaction is a savepoint: an `Err` inside rolls back only the inner part
- Using a transaction after its function returned is `PostgresTransactionEnded`
- `transaction_with!` takes `Postgres.TxOptions.{ isolation: Postgres.Isolation.Serializable }`. A serialization
  failure (`40001`) is returned, not retried; the caller decides whether to run the transaction again
- An error inside a transaction that the function swallows instead of returning leaves PostgreSQL's transaction
  failed: every later statement in it fails (`25P02`) until the function returns. If its callback returns `Ok`,
  PostgreSQL rolls back instead of committing, and `transaction!` returns `PostgresTransactionRolledBack`
- A nested transaction's `Tx` expires when its callback returns, even while its outer transaction is still active

## Connections

- The pool logs in on new connections: SCRAM-SHA-256 or a plain-text password, computed by the host with the
  password secret (it never reaches Roc). MD5 passwords are not supported. Every failed login discards its
  connection; the next request opens a new one and logs in again
- `tls: Tcp.Tls.On` (or `OnWithCaFile`) asks the server for TLS before logging in (SSLRequest) and fails when it
  refuses; it never falls back to plain text. The certificate must name `host`. Direct TLS (PostgreSQL 17's
  `sslnegotiation=direct`) is not supported yet
- Each statement has `statement_timeout_milliseconds` (30 s by default): PostgreSQL's `statement_timeout`, and the
  host waits a second longer for the answer. The host uses one monotonic budget for the whole exchange;
  additional messages, notices, and partial reads do not restart it
- A connection goes back to the pool as it is. Settings changed with `SET` stay for the next request; use
  `SET LOCAL` inside a transaction instead. A connection left inside a transaction is closed rather than returned
- Migrations in `init!` run in every process (and again when one restarts), so make them idempotent (`CREATE TABLE IF NOT EXISTS`)

## Tests

`zig build test-postgres` runs `example/` against a throwaway PostgreSQL on every backend and allocator: the
local PostgreSQL binaries when `initdb` is installed, otherwise Docker's `postgres:17`.
It also runs local protocol fixtures for failed-login cleanup and responses delivered across multiple reads.
