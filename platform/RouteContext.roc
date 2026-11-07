import Http
import PathParam

## The input a handler receives: the request, and the path parameters captured
## by the matched route. `path_params` are percent-decoded and in pattern order,
## with any nest-prefix parameters first. They are empty for a fallback handler
## and for the context seen by router-wide layers. `provided` holds the values
## the app's `BeforeBody` stages left for handlers; read it with
## `Extract.provided` and `Extract.optional`.
RouteContext(provided) := {
	request : Http.Request,
	path_params : List(PathParam),
	provided : provided,
}
