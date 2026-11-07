import Http
import Instant
import PathParam

## A request without its body: what `Middleware.Stage` callbacks and the
## `begin!` of a `Handler.streaming` handler get.
##
## - `path_params`: the matched route's parameters, as in `RouteContext`.
##   Empty for a stage of `Router.layer` running before the route is found.
## - `received_at`: when the platform started handling the request, for
##   measuring how long it took.
## - `tags`: what the matched route's `MethodRouter.tags` and `Router.add_tags`
##   give it, for a stage to read. roxum gives them no meaning.
##   Empty for a `Router.before_routing` check and a path no route has.
## - `provided`: the app's values for its handlers. It starts from
##   what `Router.build` got; a `BeforeBody` stage returns a changed copy, and
##   handlers read it with `Extract.provided` and `Extract.optional`.
## - `whole_body_limit` and `streamed_body_limit`: this request's body limits.
##   `ServerDefault` keeps the one in `Server.Limits`. `BodyLimit` sets them;
##   a `BeforeBody` stage may change them too.
RequestHead(tag, provided) := {
	method : Http.Method,
	version : Http.Version,
	raw_target : List(U8),
	path : Str,
	query : List(U8),
	headers : List(Http.RequestHeader),
	remote_addr : Http.RemoteAddr,
	request_id : Str,
	path_params : List(PathParam),
	received_at : Instant,
	tags : List(tag),
	provided : provided,
	whole_body_limit : [ServerDefault, Bytes(U64)],
	streamed_body_limit : [ServerDefault, Bytes(U64), Unlimited],
}.{
	## The head of `request`, with no path parameters or tags and the server's
	## limits.
	from_request : Http.Request, Instant, provided -> RequestHead(tag, provided)
	from_request = |request, received_at, provided| RequestHead.{
		method: request.method,
		version: request.version,
		raw_target: request.raw_target,
		path: request.path,
		query: request.query,
		headers: request.headers,
		remote_addr: request.remote_addr,
		request_id: request.request_id,
		path_params: [],
		received_at,
		tags: [],
		provided,
		whole_body_limit: ServerDefault,
		streamed_body_limit: ServerDefault,
	}

	## `request` with the metadata of `head`, keeping its body.
	apply : RequestHead(tag, provided), Http.Request -> Http.Request
	apply = |head, request| {
		..request,
		method: head.method,
		version: head.version,
		raw_target: head.raw_target,
		path: head.path,
		query: head.query,
		headers: head.headers,
		remote_addr: head.remote_addr,
		request_id: head.request_id,
	}
}
