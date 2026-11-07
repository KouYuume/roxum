import PathParam

## The result of `Router.probe`: what dispatch would do for a method and path,
## without running handlers.
##
## - `Found(params)`: a handler matches; `params` are the decoded path
##   parameters it would receive.
## - `BadPathParams`: a handler matches, but a captured value fails
##   percent-decoding, so dispatch would respond 400.
## - `MethodNotAllowed(allow)`: the path matches but no handler fits the
##   method; `allow` is the `Allow` header value a 405 would carry.
## - `NotFound`: no route matches the path, so dispatch would use the fallback.
RouteProbe := [
	Found(List(PathParam)),
	BadPathParams,
	MethodNotAllowed(Str),
	NotFound,
].{
	is_eq : _
}
