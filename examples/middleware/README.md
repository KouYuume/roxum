# Notes: tags and middleware

A small notes API that shows how routes and layers work together: a route says what it needs with tags, and layers act on those tags. The handlers contain no access checks.

| Method and path | Tags | Answers |
|---|---|---|
| `GET /notes` | none | the shared notes, to anyone |
| `GET /notes/mine` | `MembersOnly` | the signed-in user's notes; 401 without a known token |
| `POST /notes` | `MembersOnly`, `Limit(5)` | 201 with the note; 401 without a token, 429 after five posts a minute by the same user |
| `DELETE /notes/{id}` | `AdminOnly` | 204, or 404 for a note that does not exist; 401 without a token, 403 for a member |

The users and notes are fixed in the model. Requests sign in with `Authorization: Bearer alice-token` (a member) or `Bearer admin-token` (an admin). The example keeps no state: `POST` answers with the note it would store, and `DELETE` with what it would do.

```text
app.roc          the routes with their tags, and the order of the layers
Tag.roc          what a route can ask of the layers
Provided.roc     what the layers leave for the handlers
Layers.roc       authenticate, no_store, and the checks for roxum-rate-limit
CurrentUser.roc  a handler's field type for the user a layer found
Handlers.roc     the four handlers
AppState.roc     the users, notes, and rate counter made at startup
User.roc         a user and their role
```

## How it fits together

The layers are written once in `app.roc`, around all routes:

```roc
Router.new
	.route(...)
	.layer(Layers.no_store)
	.layer(Layers.authenticate)
	.layer(RateLimit.layer(Layers.post_limit))
```

- **Tags** are the app's own type, `Tag := [MembersOnly, AdminOnly, Limit(U64)]`. `MethodRouter.tags` attaches them to a route; a layer reads them as `head.tags`. roxum gives them no meaning.
- **`authenticate`** is a `BeforeBody` stage. On a route tagged `MembersOnly` or `AdminOnly`, it finds the user from the token and answers 401 or 403 before the request body is received. Its decision is the pure function `Layers.admit`.
- **Provided values** carry what a layer found to the handler. `authenticate` sets `provided.user`; a handler asks for it with a field of type `CurrentUser`, whose `parser_for` reads it with `Extract.reading`. On a route where no layer set it, the request is answered with 500, because the route is missing its tag.
- **`RateLimit.layer`** from [`roxum-rate-limit`](../../integrations/roxum-rate-limit/README.md) turns each `Limit(n)` tag into a check, and `post_limit` says which counter and key to use. It is written after `authenticate`, so it sees the user and counts per user. It counts before the body is read, so a post with an invalid body also counts.
- **`no_store`** is an `AfterHandler` stage that marks replies of routes for signed-in users as `cache-control: private, no-store`. It is written first, so it is the outermost layer and also marks the 401, 403, and 429 replies the later layers make.

The order of the stages in a request is fixed (`BeforeBody`, `OnChunk`, `AfterBody`, the handler, `AfterHandler`). Within one stage, the layers run in the order they are written. See [middleware](../../docs/guides/middleware.md) for the rules.

## Run

From the repository root, with the [pinned toolchain](../../docs/toolchain.md):

```sh
zig build host
roc build --output=notes examples/middleware/app.roc
./notes
```

The server prints its assigned port. In another terminal:

```sh
curl -i http://127.0.0.1:<port>/notes/mine
curl -i -H 'Authorization: Bearer alice-token' http://127.0.0.1:<port>/notes/mine
curl -i -X DELETE -H 'Authorization: Bearer alice-token' http://127.0.0.1:<port>/notes/1
```

`tests/middleware-example/verify.py` checks every row of the table above, in every backend.
