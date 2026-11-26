import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.Router

Model : {}

# ANCHOR: layers
## Adds `name: value` to every reply on its way out, including error replies.
tag_reply : HeaderName, HeaderValue -> List(Middleware.Stage(Model, [], {}))
tag_reply = |name, value| {
	header = ResponseHeader.{ name, value }
	[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [header]))]
}

## Rejects requests without an `x-api-key` field before the body is received
## and before the handler runs.
require_key : List(Middleware.Stage(Model, [], {}))
require_key = [
	Middleware.Stage.BeforeBody(
		|_model, head|
			if List.any(head.headers, |field| field.name == HeaderName.("x-api-key")) {
				Ok(head)
			} else {
				Err(Reply.text("missing x-api-key\n").with_status(401))
			},
	),
]

ProtectedRoutes := [].{
	routes : Router(Model, [], {})
	routes =
		Router.new
			.route("/public", MethodRouter.get(Handler.static(|{}| Reply.text("public\n"))))
			.route(
				"/private",
				MethodRouter.get(Handler.static(|{}| Reply.text("private\n")))
					.layer(require_key),
			)
			# A Router layer wraps the routes above it, with their 405 and 400 replies.
			.layer(tag_reply(HeaderName.("x-served-by"), "roxum"))
}
# ANCHOR_END: layers
