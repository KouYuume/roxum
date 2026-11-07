import Handler
import Http
import Middleware

## The handlers for one route pattern, keyed by HTTP method. Build one with a
## method function such as `get`, list several with `methods`, and pass the
## result to `Router.route`.
##
## ```roc
## MethodRouter.methods([
##     MethodRouter.get(Handler.effectful(show_user!)).tags([RateLimit(100)]),
##     MethodRouter.delete(Handler.effectful(delete_user!)).tags([RateLimit(5)]),
## ]).tags([MembersOnly])
## ```
##
## A GET handler also serves HEAD requests unless a HEAD handler is given.
MethodRouter(model, tag, provided) := List((Http.Method, { layers : List(List(Middleware.Stage(model, tag, provided))), handler : Handler(model, tag, provided), tags : List(tag) })).{
	## A method router with one OPTIONS handler. OPTIONS is never answered
	## automatically; register it explicitly when needed.
	options = |handler| MethodRouter.([(Http.Method.OPTIONS, { layers: [], handler, tags: [] })])
	## A method router with one GET handler.
	get = |handler| MethodRouter.([(Http.Method.GET, { layers: [], handler, tags: [] })])
	## A method router with one HEAD handler. It takes precedence over the GET
	## fallback for HEAD requests.
	head = |handler| MethodRouter.([(Http.Method.HEAD, { layers: [], handler, tags: [] })])
	## A method router with one POST handler.
	post = |handler| MethodRouter.([(Http.Method.POST, { layers: [], handler, tags: [] })])
	## A method router with one PUT handler.
	put = |handler| MethodRouter.([(Http.Method.PUT, { layers: [], handler, tags: [] })])
	## A method router with one DELETE handler.
	delete = |handler| MethodRouter.([(Http.Method.DELETE, { layers: [], handler, tags: [] })])
	## A method router with one PATCH handler.
	patch = |handler| MethodRouter.([(Http.Method.PATCH, { layers: [], handler, tags: [] })])
	## A method router with one QUERY handler.
	query = |handler| MethodRouter.([(Http.Method.QUERY, { layers: [], handler, tags: [] })])
	## The handlers of several method routers, for one route. Duplicates are not
	## rejected here; `Router.try_route` returns `DuplicateRoute` if the same
	## method appears twice.
	methods = |routers| MethodRouter.(List.join(List.map(routers, MethodRouter.entries)))

	## Adds `tags` to each handler already in this method router, for layers to
	## read in `RequestHead.tags`. roxum gives them no meaning.
	## A 405 for the path has no method, so it sees only `Router.add_tags`.
	tags = |MethodRouter.(items), added|
		MethodRouter.(List.map(items, |(method, target)| (method, { ..target, tags: List.concat(target.tags, added) })))

	## Adds a layer (a list of `Middleware.Stage`s, as for `Router.layer`) around
	## each handler already in this method router. Only these handlers are
	## affected: the router's 404 and 405 responses do not pass through it. A layer
	## added later is inside the
	## ones added before.
	layer = |MethodRouter.(items), stages|
		MethodRouter.(List.map(items, |(method, target)| (method, { ..target, layers: List.append(target.layers, stages) })))
	## The methods with their handlers and layers, in the order they were added.
	entries = |MethodRouter.(items)| items
}
