import Base64
import PgProtocol
import PgRows
import PgScram
import pf.Instant
import pf.Random
import pf.Secret
import pf.Tcp

## A PostgreSQL client over roxum's `Tcp` (D13): the protocol is Roc, the
## host keeps the connections. Make a pool in `init!` and keep it in the
## model.
##
## ```roc
## User : { id : I64, name : Str, email : Try(Str, [Missing]) }
##
## users : List(User)
## users = Postgres.query!(model.db, "SELECT id, name, email FROM users WHERE age > $1", [Postgres.Param.Int(20)])?
## ```
##
## Results decode into the type the caller asks for: a list of records
## whose fields match the columns by name. A NULL column is a missing field,
## so a field that may be NULL is `Try(T, [Missing])`. Parameters travel
## apart from the SQL, so values never become SQL text.
##
## Each `query!` and `execute!` borrows a connection for that statement.
## `transaction!` keeps one for its function: `Ok` commits, `Err` rolls
## back, and a transaction inside one is a savepoint. `query!`, `execute!`,
## and `transaction!` take the pool or a transaction alike.
##
## A connection goes back to the pool as it is: settings changed with `SET`
## stay for the next request, so prefer `SET LOCAL` inside a transaction.
## A connection left inside a transaction is closed instead.
Postgres := [].{
	Password := [None, Secret(Secret)]

	Config := {
		host : Str,
		port : U16 ?? 5432,
		user : Str,
		database : Str,
		password : Postgres.Password ?? Postgres.Password.None,

		## `On` asks the server for TLS before logging in, and fails when it
		## refuses: it never falls back to plain text.
		tls : Tcp.Tls ?? Tcp.Tls.Off,
		maximum_connections : U64 ?? 10,
		connect_timeout_milliseconds : U64 ?? 10_000,
		acquire_timeout_milliseconds : U64 ?? 10_000,

		## For each statement, both the server's `statement_timeout` and the
		## wait for its answer.
		statement_timeout_milliseconds : U64 ?? 30_000,
		application_name : Str ?? "roxum",
	}

	## A value for `$1`, `$2`, ... in the SQL.
	Param := [Null, Bool(Bool), Int(I64), Float(F64), Text(Str), Bytes(List(U8))]

	Isolation := [ReadCommitted, RepeatableRead, Serializable]

	TxOptions := {
		isolation : Postgres.Isolation ?? Postgres.Isolation.ReadCommitted,
	}

	## What a statement runs on: a connection, how long it may take, and how
	## deep in transactions it is (0 outside one).
	Session : { connection : Tcp.Connection, timeout : U64, depth : U64 }

	Login : {
		user : Str,
		database : Str,
		password : Postgres.Password,
		tls : Bool,
		timeout : U64,
		application_name : Str,
	}

	Pool :: { tcp : Tcp.Pool, login : Postgres.Login }.{

		## Runs `run!` on a connection from the pool, logging in first when
		## the connection is new.
		use! = |Postgres.Pool.({ tcp, login }), run!|
			Tcp.with!(
				tcp,
				|connection| {
					if Tcp.is_new!(connection) {
						match log_in!(connection, login) {
							Ok({}) => {}
							Err(problem) => {
								Tcp.discard!(connection)
								return Err(problem)
							}
						}
					}
					run!({ connection, timeout: wait_limit(login), depth: 0 })
				},
			)

		begin! = |pool, options, run!| pool.use!(|session| transact!(session, options, run!))
	}

	## A transaction in progress, valid only inside its `transaction!`.
	Tx :: { session : Postgres.Session, scope : Tcp.Scope }.{
		use! = |Postgres.Tx.({ session, scope }), run!| {
			if !Tcp.scope_active!(scope) {
				return Err(PostgresTransactionEnded)
			}
			run!(session)
		}

		begin! = |tx, _options, run!| tx.use!(|session| savepoint!(session, run!))
	}

	## Makes a pool for one database. Call it in `init!`; with TLS it fails
	## when no CA certificates can be loaded.
	pool! : Postgres.Config => Try(Postgres.Pool, [PostgresCaUnavailable, PostgresInvalidConfig, PostgresTooManyPools])
	pool! = |config| {
		made = Tcp.pool!(
			Tcp.PoolOptions.{
				host: config.host,
				port: config.port,
				# PostgreSQL asks for TLS in plain text first (SSLRequest).
				tls_later: config.tls,
				maximum_connections: config.maximum_connections,
				connect_timeout_milliseconds: config.connect_timeout_milliseconds,
				acquire_timeout_milliseconds: config.acquire_timeout_milliseconds,
			},
		)
		tcp = match made {
			Ok(pool) => pool
			Err(TcpCaUnavailable) => return Err(PostgresCaUnavailable)
			Err(TcpInvalidPool) => return Err(PostgresInvalidConfig)
			Err(TcpTooManyPools) => return Err(PostgresTooManyPools)
		}
		tls = match config.tls {
			Off => Bool.False
			_ => Bool.True
		}
		Ok(
			Postgres.Pool.(
				{
					tcp,
					login: {
						user: config.user,
						database: config.database,
						password: config.password,
						tls,
						timeout: config.statement_timeout_milliseconds,
						application_name: config.application_name,
					},
				},
			),
		)
	}

	## Runs one statement and decodes its rows into the type the caller asks
	## for. `db` is the pool or a transaction.
	query! = |db, sql, params|
		db.use!(
			|session| {
				result = exchange!(session, PgProtocol.extended_query(sql, params.map(encode)), session.depth == 0)?
				PgRows.decode(PgRows.rows(result.columns, result.rows))
			},
		)

	## Runs one statement and returns how many rows it changed, as
	## PostgreSQL reports for INSERT, UPDATE, DELETE, and similar statements.
	execute! = |db, sql, params|
		db.use!(
			|session| {
				result = exchange!(session, PgProtocol.extended_query(sql, params.map(encode)), session.depth == 0)?
				Ok(result.affected)
			},
		)

	## Runs `run!` in a transaction: `Ok` commits, `Err` rolls back. Inside
	## another transaction, it is a savepoint.
	transaction! = |db, run!| db.begin!(Postgres.TxOptions.{}, run!)

	## Like `transaction!`, with an isolation level. A Serializable or
	## RepeatableRead transaction may fail with SQLSTATE `40001`
	## (serialization failure); the caller decides whether to run it again.
	transaction_with! = |db, options, run!| db.begin!(options, run!)
}

## ---- statements ---------------------------------------------------------

encode : Postgres.Param -> PgProtocol.Text
encode = |param|
	match param {
		Null => PgProtocol.Text.Null
		Bool(value) => PgProtocol.Text.Value(
			if value {
				['t']
			} else {
				['f']
			},
		)
		Int(value) => PgProtocol.Text.Value(value.to_str().to_utf8())
		Float(value) => PgProtocol.Text.Value(float_text(value).to_utf8())
		Text(value) => PgProtocol.Text.Value(value.to_utf8())
		Bytes(value) => PgProtocol.Text.Value(['\\', 'x'].concat(hex(value)))
	}

float_text : F64 -> Str
float_text = |value|
	if value.is_nan() {
		"NaN"
	} else if value == F64.infinity {
		"Infinity"
	} else if value == -F64.infinity {
		"-Infinity"
	} else {
		value.to_str()
	}

hex : List(U8) -> List(U8)
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = List.with_capacity(bytes.len() * 2)
	for byte in bytes {
		$out = $out.append(digits.get(byte.shr_zf_wrap(4).to_u64()) ?? '0')
		$out = $out.append(digits.get(byte.bitwise_and(0x0f).to_u64()) ?? '0')
	}
	$out
}

## Sends `bytes` and reads up to ReadyForQuery. With `expect_idle`, a
## connection the statement left inside a transaction is closed when it goes
## back to the pool.
exchange! = |untimed, bytes, expect_idle| {
	session = { connection: untimed.connection, timeout: untimed.timeout, started: Instant.now!({}) }
	send!(session, bytes)?
	var $buffer = []
	var $columns = []
	var $rows = []
	var $affected = 0
	var $command = ""
	var $failure = Err(None)
	while Bool.True {
		(kind, body, rest) = receive!(session, $buffer)?
		$buffer = rest
		match kind {
			'T' => {
				$columns = PgProtocol.row_description(body).map(|column| column.name)
			}
			'D' => {
				$rows = $rows.append(PgProtocol.data_row(body))
			}
			'C' => {
				$affected = PgProtocol.affected_rows(body)
				$command = PgProtocol.command_tag(body)
			}
			'E' => {
				$failure = Ok({
					code: PgProtocol.error_field(body, 'C'),
					message: PgProtocol.error_field(body, 'M'),
					constraint: PgProtocol.error_field(body, 'n'),
				})
			}
			'Z' => {
				status = body.first() ?? 0
				# Nothing should follow ReadyForQuery; bytes that do would be
				# read as the next statement's answer.
				if !$buffer.is_empty() or (expect_idle and status != 'I') {
					Tcp.discard!(session.connection)
				}
				return match $failure {
					Ok(failure) => Err(PostgresQueryFailed(failure))
					Err(None) => Ok({ columns: $columns, rows: $rows, affected: $affected, command: $command, status })
				}
			}
			'1' | '2' | 'n' | 'I' | 's' | 'N' | 'S' | 'A' => {}
			_ => {
				Tcp.discard!(session.connection)
				return Err(PostgresProtocolFailed)
			}
		}
	}
}

transact! = |session, options, run!| {
	isolation = match options.isolation {
		ReadCommitted => "READ COMMITTED"
		RepeatableRead => "REPEATABLE READ"
		Serializable => "SERIALIZABLE"
	}
	_ = exchange!(session, PgProtocol.simple_query("BEGIN ISOLATION LEVEL ${isolation}"), Bool.False)?
	result = Tcp.scoped!(session.connection, |scope| run!(Postgres.Tx.({ session: { ..session, depth: 1 }, scope })))
	match result {
		Ok(value) => {
			committed = exchange!(session, PgProtocol.simple_query("COMMIT"), Bool.True)?
			if committed.command == "ROLLBACK" {
				return Err(PostgresTransactionRolledBack)
			}
			if committed.command != "COMMIT" or committed.status != 'I' {
				Tcp.discard!(session.connection)
				return Err(PostgresProtocolFailed)
			}
			Ok(value)
		}
		Err(problem) => {
			when_rolled_back = exchange!(session, PgProtocol.simple_query("ROLLBACK"), Bool.True)
			match when_rolled_back {
				Ok(_) => {}
				Err(_) => Tcp.discard!(session.connection)
			}
			Err(problem)
		}
	}
}

savepoint! = |session, run!| {
	name = "roxum_savepoint_${session.depth.to_str()}"
	_ = exchange!(session, PgProtocol.simple_query("SAVEPOINT ${name}"), Bool.False)?
	result = Tcp.scoped!(session.connection, |scope| run!(Postgres.Tx.({ session: { ..session, depth: session.depth + 1 }, scope })))
	match result {
		Ok(value) => {
			_ = exchange!(session, PgProtocol.simple_query("RELEASE SAVEPOINT ${name}"), Bool.False)?
			Ok(value)
		}
		Err(problem) => {
			_ = exchange!(session, PgProtocol.simple_query("ROLLBACK TO SAVEPOINT ${name}"), Bool.False)
			Err(problem)
		}
	}
}

## ---- reading and writing ------------------------------------------------

send! = |session, bytes| {
	remaining = remaining!(session)?
	match Tcp.write!(session.connection, bytes, remaining) {
		Ok({}) => Ok({})
		Err(problem) => Err(transport(problem))
	}
}

## One monotonic budget for the whole exchange, including fragmented
## messages and notices. Rounded up to the remaining whole millisecond.
remaining! = |session| {
	elapsed = Instant.nanoseconds_between(session.started, Instant.now!({}))
	match remaining_milliseconds(session.timeout, elapsed) {
		Ok(value) => Ok(value)
		Err(problem) => {
			Tcp.discard!(session.connection)
			Err(problem)
		}
	}
}

remaining_milliseconds : U64, U64 -> Try(U64, [PostgresTimedOut])
remaining_milliseconds = |timeout, elapsed_nanoseconds| {
	elapsed = elapsed_nanoseconds // 1_000_000
	if elapsed >= timeout {
		return Err(PostgresTimedOut)
	}
	Ok(timeout - elapsed)
}

## The next whole backend message: its kind, its body, and what follows.
receive! = |session, initial| {
	var $buffer = initial
	while Bool.True {
		remaining = remaining!(session)?
		match PgProtocol.next_message($buffer) {
			Message({ kind, body }, rest) => return Ok((kind, body, rest))
			Malformed => {
				Tcp.discard!(session.connection)
				return Err(PostgresProtocolFailed)
			}
			NeedMore => {
				chunk = match Tcp.read!(session.connection, 65_536, remaining) {
					Ok(bytes) => bytes
					Err(problem) => return Err(transport(problem))
				}
				$buffer = $buffer.concat(chunk)
			}
		}
	}
}

transport = |problem|
	match problem {
		TcpTimedOut => PostgresTimedOut
		TcpUnsent | TcpClosed => PostgresClosed
		TcpFailed => PostgresFailed
		TcpOverloaded => PostgresOverloaded
		TcpReleased => PostgresTransactionEnded
	}

## ---- logging in ---------------------------------------------------------

## How long the host waits for an answer: a second past the server's
## `statement_timeout`, so the server's own error arrives first.
wait_limit = |login| login.timeout + 1_000

# The selected authentication exchange must finish before ReadyForQuery.
LoginState : [Starting, PasswordSent, ScramStarted, ProofSent, SignatureVerified, Authenticated]

login_transition : LoginState, U32 -> Try(LoginState, [PostgresLoginFailed(Str)])
login_transition = |state, code|
	match (state, code) {
		(Starting, 0) | (PasswordSent, 0) | (SignatureVerified, 0) => Ok(Authenticated)
		(Starting, 3) => Ok(PasswordSent)
		(Starting, 10) => Ok(ScramStarted)
		(ScramStarted, 11) => Ok(ProofSent)
		(ProofSent, 12) => Ok(SignatureVerified)
		_ => Err(PostgresLoginFailed("unexpected authentication message"))
	}

log_in! = |connection, login| {
	session = { connection, timeout: wait_limit(login), depth: 0, started: Instant.now!({}) }
	if login.tls {
		send!(session, PgProtocol.ssl_request)?
		remaining = remaining!(session)?
		answer = match Tcp.read!(connection, 1, remaining) {
			Ok(bytes) => bytes
			Err(problem) => return Err(transport(problem))
		}
		if answer != ['S'] {
			Tcp.discard!(connection)
			return Err(PostgresTlsRefused)
		}
		tls_remaining = remaining!(session)?
		match Tcp.start_tls!(connection, tls_remaining) {
			Ok({}) => {}
			Err(TcpTlsFailed) => return Err(PostgresTlsFailed)
			Err(TcpTimedOut) => return Err(PostgresTimedOut)
			Err(TcpClosed) => return Err(PostgresClosed)
			Err(TcpFailed) => return Err(PostgresFailed)
			Err(TcpReleased) => return Err(PostgresTransactionEnded)
		}
	}
	send!(
		session,
		PgProtocol.startup([
			("user", login.user),
			("database", login.database),
			("application_name", login.application_name),
			("client_encoding", "UTF8"),
			("statement_timeout", login.timeout.to_str()),
		]),
	)?
	client_nonce = Base64.encode(u64_bytes(Random.u64!({})).concat(u64_bytes(Random.u64!({}))))
	first_bare = PgScram.client_first_bare(client_nonce)
	var $buffer = []
	var $expected_signature = ""
	var $auth_state = Starting
	while Bool.True {
		(kind, body, rest) = receive!(session, $buffer)?
		$buffer = rest
		match kind {
			'R' => {
				if body.len() < 4 {
					return Err(PostgresLoginFailed("truncated authentication message"))
				}
				code = PgProtocol.auth_code(body)
				next_state = login_transition($auth_state, code)?
				if code == 3 {
					secret = password_of(login)?
					# 'p', the length, the password, and NUL, all written by
					# the host.
					message = [Concat(Bytes(['p']), Concat(Be32LengthPlus(SecretValue, 5), Concat(SecretValue, Bytes([0]))))]
					remaining = remaining!(session)?
					match Tcp.write_derived!(connection, secret, message, remaining) {
						Ok({}) => {}
						Err(TcpSecretRefused) => return Err(PostgresLoginFailed("the password secret is unknown"))
						Err(TcpTimedOut) => return Err(PostgresTimedOut)
						Err(TcpUnsent) | Err(TcpClosed) => return Err(PostgresClosed)
						Err(TcpFailed) => return Err(PostgresFailed)
						Err(TcpReleased) => return Err(PostgresTransactionEnded)
					}
				} else if code == 10 {
					if !PgProtocol.sasl_mechanisms(body).contains("SCRAM-SHA-256") {
						return Err(PostgresLoginFailed("the server offers no supported SASL mechanism"))
					}
					send!(session, PgProtocol.sasl_initial("SCRAM-SHA-256", "n,,${first_bare}".to_utf8()))?
				} else if code == 11 {
					secret = password_of(login)?
					server_first = Str.from_utf8(body.drop_first(4)) ?? ""
					first = match PgScram.parse_server_first(client_nonce, server_first) {
						Ok(value) => value
						Err(_) => return Err(PostgresLoginFailed("invalid SCRAM server-first message"))
					}
					final_without_proof = PgScram.without_proof(first.nonce)
					auth = PgScram.auth_message(first_bare, server_first, final_without_proof)
					derived = match Secret.derive!(secret, PgScram.proof_and_signature(first, auth)) {
						Ok(values) => values
						Err(_) => return Err(PostgresLoginFailed("the host could not compute the SCRAM proof"))
					}
					$expected_signature = Base64.encode(derived.get(1) ?? [])
					send!(session, PgProtocol.sasl_response(PgScram.client_final(final_without_proof, derived.get(0) ?? []).to_utf8()))?
				} else if code == 12 {
					server_final = Str.from_utf8(body.drop_first(4)) ?? ""
					if server_final != "v=${$expected_signature}" {
						return Err(PostgresLoginFailed("the server's SCRAM signature does not match"))
					}
				}
				$auth_state = next_state
			}
			'E' => return Err(PostgresLoginFailed(PgProtocol.error_field(body, 'M')))
			'Z' => {
				if $auth_state != Authenticated {
					return Err(PostgresLoginFailed("authentication did not finish"))
				}
				return Ok({})
			}
			_ => {}
		}
	}
}

password_of = |login|
	match login.password {
		Secret(secret) => Ok(secret)
		None => Err(PostgresLoginFailed("the server asks for a password"))
	}

u64_bytes : U64 -> List(U8)
u64_bytes = |value| [0, 8, 16, 24, 32, 40, 48, 56].map(|shift| value.shr_zf_wrap(shift).to_u8_wrap())

expect encode(Postgres.Param.Bytes([0, 255])) == PgProtocol.Text.Value("\\x00ff".to_utf8())
expect encode(Postgres.Param.Bool(Bool.True)) == PgProtocol.Text.Value(['t'])
expect encode(Postgres.Param.Int(-42)) == PgProtocol.Text.Value("-42".to_utf8())
expect encode(Postgres.Param.Float(-F64.infinity)) == PgProtocol.Text.Value("-Infinity".to_utf8())
expect encode(Postgres.Param.Null) == PgProtocol.Text.Null

# The monotonic clock supplies whole nanoseconds: just before, exactly at,
# and just after the deadline. A positive fraction rounds up to 1 ms.
expect remaining_milliseconds(1_100, 1_099_999_999) == Ok(1)
expect remaining_milliseconds(1_100, 1_100_000_000) == Err(PostgresTimedOut)
expect remaining_milliseconds(1_100, 1_100_000_001) == Err(PostgresTimedOut)
expect remaining_milliseconds(0, 0) == Err(PostgresTimedOut)

# Each accepted authentication path and each premature completion class.
expect login_transition(Starting, 0) == Ok(Authenticated)
expect login_transition(Starting, 3) == Ok(PasswordSent)
expect login_transition(PasswordSent, 0) == Ok(Authenticated)
expect login_transition(Starting, 10) == Ok(ScramStarted)
expect login_transition(ScramStarted, 11) == Ok(ProofSent)
expect login_transition(ProofSent, 12) == Ok(SignatureVerified)
expect login_transition(SignatureVerified, 0) == Ok(Authenticated)
expect List.all([ScramStarted, ProofSent, Authenticated], |state| login_transition(state, 0).is_err())
expect List.all([Starting, PasswordSent, ScramStarted, SignatureVerified, Authenticated], |state| login_transition(state, 12).is_err())
expect login_transition(ProofSent, 11).is_err()
expect login_transition(ScramStarted, 10).is_err()
