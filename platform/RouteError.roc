## Why a route could not be added to a `Router`. Returned by the `Router.try_*`
## functions; the non-`try` versions crash with a message instead.
##
## - `InvalidPattern(pattern)`: the pattern does not start with `/` (and is not
##   `*`), has a malformed `{...}` segment or parameter name, or was registered
##   with an empty method router.
## - `CatchAllMustBeLast(pattern)`: a `{*name}` segment is not the last one.
## - `DuplicateParameter(name)`: a parameter name appears twice in a pattern,
##   or a nest prefix and a nested route share a name. In the nest case the
##   payload is `"nested route"`, not the parameter name.
## - `DuplicateRoute(pattern)`: the method is already registered for a pattern
##   with the same structure. Parameter names do not count. For `merge` and
##   `nest` the payload is `"merged route"` or `"nested route"`.
## - `InvalidAsteriskMethod`: the `*` pattern was given a method other than
##   OPTIONS.
## - `CatchAllInNestPrefix`: a nest prefix contains a catch-all.
## - `DuplicateFallback`: a second custom fallback was set, or a nested router's
##   fallback would answer under a prefix that already has one.
## - `MergedFallback`: the right-hand router in a merge has its own fallback.
## - `NestedBeforeRouting`: the router passed to `nest` has `before_routing`
##   checks.
## - `MergedBeforeRouting`: the right-hand router in a merge has them.
RouteError := [
	InvalidPattern(Str),
	CatchAllMustBeLast(Str),
	DuplicateParameter(Str),
	DuplicateRoute(Str),
	InvalidAsteriskMethod,
	CatchAllInNestPrefix,
	DuplicateFallback,
	MergedFallback,
	NestedBeforeRouting,
	MergedBeforeRouting,
]
