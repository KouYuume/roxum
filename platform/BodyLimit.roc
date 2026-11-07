import Middleware
import Server

## Layers that change a route's request body limits from `Server.Limits`
##. Apply them to the routes that take larger (or smaller) bodies with
## `MethodRouter.layer`, or to the routes written above it with `Router.layer`:
##
## ```roc
## Router.route(
##     "/files",
##     MethodRouter.post(Handler.streaming(upload))
##         .layer(BodyLimit.streamed(Server.BodyLimit.Bytes(1_073_741_824))),
## )
## ```
##
## Each is a `BeforeBody` stage that sets the limit in the request's
## `RequestHead`, so a layer nearer the handler wins: a route's layer over the
## router's.
BodyLimit := [].{
	## The limit, in bytes, of a body received whole before the handler runs
	## (`Server.Limits.maximum_body_bytes`).
	whole : U64 -> List(Middleware.Stage(model, tag, provided))
	whole = |bytes| [Middleware.Stage.BeforeBody(|_model, head| Ok({ ..head, whole_body_limit: Bytes(bytes) }))]

	## The limit of a body read by a `Handler.streaming` handler
	## (`Server.Limits.maximum_streamed_body_bytes`).
	streamed : Server.BodyLimit -> List(Middleware.Stage(model, tag, provided))
	streamed = |limit| {
		set = match limit {
			Server.BodyLimit.Unlimited => Unlimited
			Server.BodyLimit.Bytes(count) => Bytes(count)
		}
		[Middleware.Stage.BeforeBody(|_model, head| Ok({ ..head, streamed_body_limit: set }))]
	}
}
