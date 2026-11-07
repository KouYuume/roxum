# Users: a DDD example

A user service with creation, lookup, and filtered search. It separates HTTP
handling, application use cases, domain validation, and PostgreSQL adapters.

```text
app.roc                              Roc platform entry point
api/
  Main.roc                           startup orchestration
  AppConfig.roc, config/              configuration loading
  AppState.roc                        binds database operations to the shared pool
  Routes.roc                          HTTP routes
  HandlerError.roc                    application errors to HTTP responses
  handlers/users/                    CreateUser, GetUser, SearchUsers handlers
core/
  domain/user/                       User, Email, repository function signatures
  usecases/users/                    CreateUser, GetUser, SearchUsers
  query_services/users/              search query, DTO, and query-service port
  errors/                            domain, infrastructure, application errors
infrastructure/
  database/                          connection pool and schema setup
  repositories/                      UserRepositoryImpl
  query_services/users/              UserSearchImpl
  UserId.roc             UUIDv7 from time and operating-system randomness
migrations/                          users table schema
```

## Dependency direction

Core has no HTTP, logging, or PostgreSQL imports. Its domain functions are pure.
Use cases are effectful functions with explicit dependencies, rather than objects
with constructors. Repository and query-service contracts name function types;
there are no callback-wrapper objects or forwarding methods. `AppState` binds
these functions to the shared PostgreSQL pool once at startup.

Handlers declare their inputs with `Handler.typed` and `Extract.JsonBody`, `Extract.Path`,
and `Extract.Query`. JSON and query extraction failures are captured as values so
the API can preserve its 400 responses. Validated users are projected once with
`User.to_data`; search results already have that shape and pass directly to JSON.

Repository lookup returns a domain entity or absence. Search uses a separate
query service that returns DTOs directly. `CreateUser` validates a user and asks
its repository to save it. The adapter
executes one atomic INSERT (with an ID-conflict update). These three operations
do not require an application-level multi-statement transaction.

Time and randomness are acquired by the ID adapter. `User.new` receives an ID
and remains pure. This example uses UUIDv7 but does not promise ordering among
IDs generated within the same millisecond.

## HTTP API

| Method and path | Input | Success |
|---|---|---|
| `POST /users` | JSON `{ "name": "Alice", "email": "alice@example.com" }` | 200, created user |
| `GET /users/{id}` | UUID path parameter | 200, user; 404 if absent |
| `GET /users?name=Alice&email=alice@example.com` | At least one optional filter | 200, array of users |

Every user response has `id`, `name`, and `email`. Search uses exact equality;
when both filters are present they are combined with AND. An explicit empty
filter is a value, while no filters is a 400. SQL parameters are bound values.

Invalid request JSON and domain validation return 400. Database failures return
500 without database diagnostics; this includes malformed UUIDs and names longer
than the database's 40-character limit. Names may be empty, and emails are not
unique. The example's email validator accepts ASCII word characters, dots, and
hyphens around `@`, requires a dotted suffix, and limits the value to 254 bytes.
It does not implement Unicode regular-expression word classes or full RFC email
syntax. Authentication, request identity propagation, and OpenAPI generation are
outside this example.

## Run

Use the [pinned toolchain](../../docs/toolchain.md). From the repository root:

```sh
docker run -d --name roxum-ddd-db -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app-password -e POSTGRES_DB=app postgres:17
printf 'app-password\n' > examples/ddd/api/config/database-password
zig build examples
cd examples/ddd/api
../../../zig-out/bin/roxum-ddd
```

Startup applies the idempotent schema and prints the assigned port. From another
terminal, replace `<port>` with that value:

```sh
curl -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice@example.com"}' http://127.0.0.1:<port>/users
curl http://127.0.0.1:<port>/users/<returned-id>
curl 'http://127.0.0.1:<port>/users?name=Alice'
```

Stop the app with Ctrl-C and remove the example database with
`docker rm -f roxum-ddd-db`. `config/local.toml` in the working directory overrides
the embedded settings. Keep database credentials in the ignored password file.

## Verify

`zig build test-m9b-5` runs domain and UUID tests, the negative effect-boundary
fixture, and the users API against temporary PostgreSQL databases in all three
compiler backends and both allocator modes. It checks create/read/search,
filter combinations, email-length boundaries, malformed input, failed-write
recovery, concurrent unique IDs, and request allocation cleanup.
