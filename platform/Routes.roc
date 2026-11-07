import Http
import Reply

## A finished router, made by `Router.build`, which the platform runs. Its tag
## and provided types are closed inside, so the app's `program` names only its
## model.
Routes(model) := {
	dispatch! : model, Http.Request => { response : Http.Response, route : Try(Str, [Unrouted]), reply : Reply },
	patterns : {} -> List(Str),
}.{
	## Routes `request`, and names the route pattern that answered, as
	## `Router.dispatch_with_route!` does.
	dispatch_with_route! = |Routes.(routes), model, request| (routes.dispatch!)(model, request)

	## The route patterns the router answers with, for the host's metrics.
	route_patterns = |Routes.(routes)| (routes.patterns)({})
}
