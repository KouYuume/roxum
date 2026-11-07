import Handler
import Instant
import Pipeline
import RequestHead
import HeaderValue
import Http
import MethodRouter
import Middleware
import PercentEncoding
import PathParam
import Reply
import RouteContext
import RouteError
import RouteProbe
import Routes
import Respond

Segment := [Static(Str), Param, CatchAll, Asterisk].{ is_eq : _ }
## `router_layers` are the ones `Router.layer` added to this router, written
## first outermost. `inner_layers` are inside them: a method router's own
## layers, and those a nested or merged router brought with it. A layer added
## by a parent therefore goes outside what the child built.
Endpoint(model, tag, provided) := {
	method : Http.Method,
	handler : Handler(model, tag, provided),
	tags : List(tag),
	router_layers : List(List(Middleware.Stage(model, tag, provided))),
	inner_layers : List(List(Middleware.Stage(model, tag, provided))),
	param_names : List(Str),
	route : Str,
}
## A path's own layers answer its 405 and 400: they are the `Router.layer`
## layers written after the path, without any method's layers.
Route(model, tag, provided) := {
	segments : List(Segment),
	endpoints : List(Endpoint(model, tag, provided)),
	tags : List(tag),
	router_layers : List(List(Middleware.Stage(model, tag, provided))),
	inner_layers : List(List(Middleware.Stage(model, tag, provided))),
}
StaticEdge := { value : Str, child : U64 }
TrieNode(model, tag, provided) := {
	static_edges : List(StaticEdge),
	## The same edges by value, consulted once a node has more than
	## `linear_static_edges` of them: hashing a segment costs more than a few
	## string comparisons.
	static_index : Dict(Str, U64),
	param_child : [None, Some(U64)],
	catch_child : [None, Some(U64)],
	asterisk_child : [None, Some(U64)],
	endpoints : List(Endpoint(model, tag, provided)),
	path_tags : List(tag),
	path_layers : List(List(Middleware.Stage(model, tag, provided))),
}
## A custom fallback answers under `prefix`; the root one has an empty prefix.
Fallback(model, tag, provided) := {
	prefix : List(Segment),
	answer! : Router.Unmatched, model, RequestHead(tag, provided) => Try(Reply, Reply),
	tags : List(tag),
	router_layers : List(List(Middleware.Stage(model, tag, provided))),
	inner_layers : List(List(Middleware.Stage(model, tag, provided))),
}

## Maps request paths and methods to handlers. Build a router at the top level
## of the app with `new`, add routes with `route`, and hand it to the platform
## as `routes`.
##
## A pattern starts with `/` and is split on `/` into segments. Each segment is
## static text, a parameter `{name}` that matches one non-empty segment, or a
## catch-all `{*name}` that matches the non-empty rest of the path and must be
## the last segment. Parameter names are ASCII identifiers (a letter or `_`,
## then letters, digits, or `_`) and must be unique within a pattern. The
## pattern `*` matches only the asterisk-form target (`OPTIONS *`) and accepts
## only OPTIONS; `/*` is an ordinary static segment. A static segment cannot be
## `.` or `..`. A trailing slash is not removed: `/users` and `/users/` are
## different routes.
##
## Static segments are compared after normalizing percent-encoding (RFC 3986
## §6.2.2) on both sides: an encoded unreserved character is decoded and other
## escapes use uppercase hex. So `/%61dmin` matches the static route `/admin`,
## and the route's layers run for it. `%2F` stays encoded and never separates
## segments.
##
## Dispatch first picks a path, then a method. At each segment a static match
## is tried before a parameter, and a parameter before a catch-all; a branch
## that fails later backtracks to the next kind. Registration order does not
## matter. Once a path matches, the method is resolved only among that path's
## endpoints:
##
## - An explicit HEAD handler is used if present; otherwise HEAD falls back to
##   the GET handler.
## - If no handler fits the method, the response is 405 with an `Allow` header
##   listing the path's methods in the order OPTIONS, GET, HEAD, POST, PUT,
##   DELETE, PATCH, QUERY. A GET handler implies HEAD. A less specific path
##   that does have the method is not tried.
## - Captured values are percent-decoded after the path is matched, so `%2F`
##   stays inside one parameter. A capture that is not valid percent-encoding,
##   does not decode to UTF-8, contains NUL, or has a `.` or `..` segment after
##   decoding (such as `%2e%2e` or `..%2F`) gives an empty 400 response, so a
##   decoded value is never a path-traversal step.
## - A path with no match goes to the fallback: an empty 404 by default. A
##   custom fallback also answers a 405 or that 400 in its place.
##
## OPTIONS is never registered automatically.
Router(model, tag, provided) :: {
	routes : List(Route(model, tag, provided)),
	nodes : List(TrieNode(model, tag, provided)),
	fallbacks : List(Fallback(model, tag, provided)),
	default_tags : List(tag),
	## The layers of the default 404, which stands where `Router.new` is written
	##: every `Router.layer` of this router is around it.
	default_layers : List(List(Middleware.Stage(model, tag, provided))),
	before_routing_checks : List((model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply))),
}.{
	## Why a fallback was called: no route has this path, the path's route has
	## no handler for the method (with the methods it has), or a path parameter
	## was invalid.
	Unmatched := [NotFound, MethodNotAllowed(List(Http.Method)), BadPath]

	## A router with no routes, the default 404 fallback, and no layer.
	new = Router.({ routes: [], nodes: [empty_node], fallbacks: [], default_tags: [], default_layers: [], before_routing_checks: [] })

	## Adds the handlers of `method_router` under `pattern`. If a route with the
	## same segment structure already exists, the new methods are added to it.
	##
	## Returns `Err` with a `RouteError` when the pattern is invalid, the method
	## router is empty (`InvalidPattern`), a method is already registered for the
	## same structure (`DuplicateRoute`; parameter names are ignored in this
	## comparison), or `*` is used with a method other than OPTIONS
	## (`InvalidAsteriskMethod`).
	try_route = |Router.(router), pattern, method_router| {
		methods = MethodRouter.entries(method_router)
		match parse_pattern(pattern) {
			Err(error) => Err(error)
			Ok(parsed) =>
				match add_route(router, pattern, parsed, methods) {
					Ok(updated) => Ok(Router.(updated))
					Err(error) => Err(error)
				}
		}
	}

	## Same as `try_route`, but crashes with a descriptive message on error. Use it
	## for routers built from constants at the top level, where the crash is
	## reported when the app is built.
	route = |router, pattern, methods|
		match Router.try_route(router, pattern, methods) {
			Ok(updated) => updated
			Err(error) => crash error_message(error)
		}

	## Sets the function that answers when no handler can be called: for a
	## path with no route (`NotFound`), a method its route does not have
	## (`MethodNotAllowed`; `Allow` is added if the reply has none), or an
	## invalid path parameter (`BadPath`). It gets the request's metadata: the
	## body is not received. A router passed to `nest` answers for the paths
	## under its prefix with its own fallback, and the root's answers for the
	## rest. Returns `Err(DuplicateFallback)` if this router already has one.
	try_fallback = |Router.(router), answer!|
		if List.any(router.fallbacks, |entry| List.is_empty(entry.prefix)) {
			Err(DuplicateFallback)
		} else {
			Ok(Router.({ ..router, fallbacks: List.append(router.fallbacks, { prefix: [], answer!, tags: [], router_layers: [], inner_layers: [] }) }))
		}

	## Same as `try_fallback`, but crashes on error.
	fallback = |router, answer!|
		match Router.try_fallback(router, answer!) {
			Ok(updated) => updated
			Err(error) => crash error_message(error)
		}

	## Adds a layer around what is written above it in this router: its routes,
	## with their 405 and 400 replies, what `nest` and `merge` added, its
	## fallback, and the default 404, which stands where `Router.new` is written
	##. A route added later is not inside it. A layer is a list of `Middleware.Stage`s that
	## share one position: a reply its own `BeforeBody` made does
	## not go through its own `AfterHandler`. A layer added later is inside the
	## ones added before, and a route's own layers
	## (`MethodRouter.layer`) are inside all of them.
	layer = |Router.(router), stages| {
		routes = List.map(
			router.routes,
			|existing| {
				..existing,
				router_layers: List.append(existing.router_layers, stages),
				endpoints: List.map(existing.endpoints, |endpoint| { ..endpoint, router_layers: List.append(endpoint.router_layers, stages) }),
			},
		)
		fallbacks = List.map(router.fallbacks, |entry| { ..entry, router_layers: List.append(entry.router_layers, stages) })
		Router.({ ..router, routes, nodes: build_nodes(routes), fallbacks, default_layers: List.append(router.default_layers, stages) })
	}

	## Adds `tags` to what is written above it in this router, the same as `layer`
	## covers, for layers to read in `RequestHead.tags`. Unlike
	## `MethodRouter.tags`, a 405 for those paths sees them too. A nested or
	## merged router's tags stay on its routes.
	add_tags = |Router.(router), added| {
		routes = List.map(
			router.routes,
			|existing| {
				..existing,
				tags: List.concat(existing.tags, added),
				endpoints: List.map(existing.endpoints, |endpoint| { ..endpoint, tags: List.concat(endpoint.tags, added) }),
			},
		)
		fallbacks = List.map(router.fallbacks, |entry| { ..entry, tags: List.concat(entry.tags, added) })
		Router.({ ..router, routes, nodes: build_nodes(routes), fallbacks, default_tags: List.concat(router.default_tags, added) })
	}

	## Finishes the router for the platform: the app's
	## `program` hands over this, naming only its model. `initial` is what
	## `RequestHead.provided` starts from for each request; `{}` if the app has
	## no provided values.
	build : Router(model, tag, provided), provided -> Routes(model)
	build = |router, initial|
		Routes.({
			dispatch!: |model, request| Router.dispatch_with_route!(router, initial, model, request),
			# A function, because `program` holds functions, so it is not a constant
			# and this runs for each request; the patterns are read once, at startup.
			patterns: |{}| Router.route_patterns(router),
		})

	## Runs `check!` for every request before the route is found, in the order
	## added, wherever it is written. It may change the path
	## the router matches, or answer at once; that reply goes through no layer.
	## Only the router the app hands to the platform can have one: `nest` and
	## `merge` reject a router that does.
	before_routing = |Router.(router), check!| Router.({ ..router, before_routing_checks: List.append(router.before_routing_checks, check!) })

	## Adds every route of `right` to `left`, at the same paths. `right`'s layers
	## stay on `right`'s routes. A path both have keeps only the layers of each
	## method and of `left` added later: a 405 for it belongs to neither side.
	## `left`'s later layers go outside them.
	##
	## Returns `Err(MergedFallback)` if `right` has its own fallback (it has no
	## paths of its own to answer for), `Err(MergedBeforeRouting)` if it has
	## `before_routing` checks, and `Err(DuplicateRoute("merged route"))` if both
	## register the same method for the same path structure.
	try_merge = |Router.(left), Router.(right)|
		if !List.is_empty(right.before_routing_checks) {
			Err(MergedBeforeRouting)
		} else if List.any(right.fallbacks, |entry| List.is_empty(entry.prefix)) {
			Err(MergedFallback)
		} else {
			match merge_routers(left, right) {
				Ok(updated) => Ok(Router.(updated))
				Err(error) => Err(error)
			}
		}

	## Same as `try_merge`, but crashes on error.
	merge = |left, right|
		match Router.try_merge(left, right) {
			Ok(updated) => updated
			Err(error) => crash error_message(error)
		}

	## Mounts every route of `child` under `prefix`. The prefix may contain static
	## segments and parameters but not a catch-all. Prefix parameters come
	## before the child's parameters in `path_params`. A child route `/` maps to
	## the prefix itself, and a prefix `/` leaves the child paths unchanged. A
	## child `*` route stays `*`: the asterisk form names the whole server.
	## `child`'s layers stay on its routes, and its fallback answers under the
	## prefix.
	##
	## Returns `Err` if `child` has `before_routing` checks
	## (`NestedBeforeRouting`), if the prefix is invalid, is `*`, or ends in `/`
	## (`InvalidPattern`; nested paths would contain `//`, which the host
	## rejects), if it contains a catch-all (`CatchAllInNestPrefix`), if a
	## prefix parameter name repeats a child
	## parameter name (`DuplicateParameter`), if a nested route collides with
	## an existing one (`DuplicateRoute`), or if a fallback already answers
	## under that prefix (`DuplicateFallback`).
	try_nest = |Router.(parent), prefix, Router.(child)|
		if !List.is_empty(child.before_routing_checks) {
			Err(NestedBeforeRouting)
		} else {
			match parse_pattern(prefix) {
				Err(error) => Err(error)
				Ok(prefix_parsed) =>
					if prefix_parsed.asterisk or ends_with_empty_segment(prefix_parsed.segments) {
						Err(InvalidPattern(prefix))
					} else if List.any(prefix_parsed.segments, |segment| segment == CatchAll) {
						Err(CatchAllInNestPrefix)
					} else {
						mount_prefix = if prefix == "/" { [] } else { prefix_parsed.segments }
						match nest_routes(parent, prefix_parsed, child.routes) {
							Err(error) => Err(error)
							Ok(updated) =>
								match add_fallbacks(updated, mount_prefix, child.fallbacks) {
									Err(error) => Err(error)
									Ok(with_fallbacks) => Ok(Router.(with_fallbacks))
								}
						}
					}
			}
		}

	## Same as `try_nest`, but crashes on error.
	nest = |parent, prefix, child|
		match Router.try_nest(parent, prefix, child) {
			Ok(updated) => updated
			Err(error) => crash error_message(error)
		}

	## Routes `request` through the router's layer and matched handler, and
	## converts the resulting `Reply` into an `Http.Response`. Both `Ok` and
	## `Err` replies from handlers become responses.
	dispatch! = |router, initial, model, request| (Router.dispatch_with_route!(router, initial, model, request)).response

	## Like `dispatch!`, and also names the route pattern that answered, as the
	## reply was marked (`Reply.route`): the matched route's pattern, with any
	## nest prefix and static segments in normalized form, such as
	## `/api/users/{id}`, or `fallback` for a custom fallback. A 405, the
	## default 404, and a reply a layer made without the inner one have none.
	## The platform calls this for each request; the access log names the route.
	dispatch_with_route! = |Router.(router), initial, model, request| dispatch_router!(router, initial, model, request)

	## The route patterns the router answers with, as `dispatch_with_route!`
	## names them, each once, and `fallback` when the router has a custom
	## fallback. The host's metrics count requests by these.
	route_patterns = |Router.(router)| {
		var $patterns = []
		for registered in router.routes {
			for endpoint in registered.endpoints {
				if !List.contains($patterns, endpoint.route) { $patterns = List.append($patterns, endpoint.route) }
			}
		}
		if List.is_empty(router.fallbacks) { $patterns } else { List.append($patterns, "fallback") }
	}

	## Reports how `method` and `path` would be routed without running any
	## handler or layer. Uses the same matching, HEAD fallback, and
	## percent-decoding as dispatch. See `RouteProbe`.
	probe = |Router.(router), method, path| probe_router(router, method, path)
}

parse_pattern = |pattern|
	if pattern == "*" {
		Ok({ segments: [Asterisk], param_names: [], asterisk: Bool.True })
	} else if !Str.starts_with(pattern, "/") {
		Err(InvalidPattern(pattern))
	} else {
		parse_segments(List.drop_first(Str.split_on(pattern, "/"), 1), pattern)
	}

parse_segments = |parts, pattern| {
	var $segments = []
	var $names = []
	var $index = 0
	while $index < List.len(parts) {
		part = list_get(parts, $index)
		match parse_segment(part) {
			Err(_) => return Err(InvalidPattern(pattern))
			Ok(Static(value)) => { $segments = List.append($segments, Static(value)) }
			Ok(ParamName(name)) => {
				if List.any($names, |existing| existing == name) { return Err(DuplicateParameter(name)) }
				$segments = List.append($segments, Param)
				$names = List.append($names, name)
			}
			Ok(CatchAllName(name)) => {
				if $index + 1 != List.len(parts) { return Err(CatchAllMustBeLast(pattern)) }
				if List.any($names, |existing| existing == name) { return Err(DuplicateParameter(name)) }
				$segments = List.append($segments, CatchAll)
				$names = List.append($names, name)
			}
		}
		$index = $index + 1
	}
	Ok({ segments: $segments, param_names: $names, asterisk: Bool.False })
}

parse_segment = |segment|
	if Str.starts_with(segment, "{") and Str.ends_with(segment, "}") {
		bytes = Str.to_utf8(segment)
		inner_bytes = List.sublist(bytes, { start: 1, len: List.len(bytes) - 2 })
		if List.first(inner_bytes) == Ok(42) {
			name = Str.from_utf8_lossy(List.drop_first(inner_bytes, 1))
			if valid_name(name) { Ok(CatchAllName(name)) } else { Err(Invalid) }
		} else {
			name = Str.from_utf8_lossy(inner_bytes)
			if valid_name(name) { Ok(ParamName(name)) } else { Err(Invalid) }
		}
	} else if Str.starts_with(segment, "{") or Str.ends_with(segment, "}") {
		Err(Invalid)
	} else if segment == "." or segment == ".." {
		Err(Invalid)
	} else {
		Ok(Static(normalize_segment(segment)))
	}

valid_name = |name| {
	bytes = Str.to_utf8(name)
	if List.is_empty(bytes) {
		Bool.False
	} else {
		first = list_get(bytes, 0)
		(is_ascii_alpha(first) or first == 95)
			and List.all(List.drop_first(bytes, 1), |byte| is_ascii_alpha(byte) or (byte >= 48 and byte <= 57) or byte == 95)
	}
}

is_ascii_alpha = |byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

add_route = |router, pattern, parsed, methods| {
	if List.is_empty(methods) { return Err(InvalidPattern(pattern)) }
	route_pattern = render_route(parsed.segments, parsed.param_names)
	if parsed.asterisk and List.any(methods, |(method, _)| method != Http.Method.OPTIONS) { return Err(InvalidAsteriskMethod) }
	var $route_index = 0
	while $route_index < List.len(router.routes) {
		route = list_get(router.routes, $route_index)
		if route.segments == parsed.segments {
			updated_endpoints = append_endpoints(route.endpoints, methods, parsed.param_names, route_pattern, pattern)?
			added = List.drop_first(updated_endpoints, List.len(route.endpoints))
			return Ok({
				..router,
				routes: list_set(router.routes, $route_index, { ..route, endpoints: updated_endpoints }),
				nodes: insert_endpoints(router.nodes, parsed.segments, added, route.tags, flat_layers(route)),
			})
		}
		$route_index = $route_index + 1
	}
	endpoints = append_endpoints([], methods, parsed.param_names, route_pattern, pattern)?
	Ok({
		..router,
		routes: List.append(router.routes, { segments: parsed.segments, endpoints, tags: [], router_layers: [], inner_layers: [] }),
		nodes: insert_endpoints(router.nodes, parsed.segments, endpoints, [], []),
	})
}

append_endpoints = |endpoints, methods, param_names, route, pattern| {
	var $endpoints = endpoints
	for (method, target) in methods {
		if List.any($endpoints, |endpoint| endpoint.method == method) { return Err(DuplicateRoute(pattern)) }
		$endpoints = List.append($endpoints, { method, handler: target.handler, tags: target.tags, router_layers: [], inner_layers: target.layers, param_names, route })
	}
	Ok($endpoints)
}

## The pattern a route answers to, written back from its parsed segments, so a
## merged or nested route reads as one pattern and static segments appear in
## the normalized form they match in.
render_route = |segments, param_names| {
	if segments == [Asterisk] { return "*" }
	var $parts = []
	var $name_index = 0
	for segment in segments {
		match segment {
			Static(value) => { $parts = List.append($parts, value) }
			Param => {
				$parts = List.append($parts, "{${list_get(param_names, $name_index)}}")
				$name_index = $name_index + 1
			}
			CatchAll => {
				$parts = List.append($parts, "{*${list_get(param_names, $name_index)}}")
				$name_index = $name_index + 1
			}
			Asterisk => { $parts = List.append($parts, "*") }
		}
	}
	"/${Str.join_with($parts, "/")}"
}

merge_routers = |left, right| {
	merged = merge_routes_help(left, right.routes, 0)?
	add_fallbacks(merged, [], right.fallbacks)
}

merge_routes_help = |router, routes, index|
	if index == List.len(routes) {
		Ok({ ..router, nodes: build_nodes(router.routes) })
	} else {
		route = list_get(routes, index)
		updated = merge_route_endpoints(router, route.segments, route.endpoints, 0)?
		merge_routes_help(with_child_path_layers(updated, router, route, route.segments), routes, index + 1)
	}

merge_route_endpoints = |router, segments, endpoints, index|
	if index == List.len(endpoints) {
		Ok(router)
	} else {
		endpoint = list_get(endpoints, index)
		parsed = { segments, param_names: endpoint.param_names, asterisk: segments == [Asterisk] }
		updated = add_route(router, "merged route", parsed, [(endpoint.method, { layers: flat_layers(endpoint), handler: endpoint.handler, tags: endpoint.tags })])?
		merge_route_endpoints(updated, segments, endpoints, index + 1)
	}

## The layers outermost first, for a parent to wrap as one.
flat_layers = |scoped| List.concat(scoped.router_layers, scoped.inner_layers)

## After `child_route` was added at `segments`: a new path keeps the child's
## layers for its 405 and 400; a path that already existed has two owners, so
## it keeps none.
with_child_path_layers = |updated, before, child_route, segments| {
	existed = List.any(before.routes, |route| route.segments == segments)
	own = if existed { [] } else { flat_layers(child_route) }
	own_tags = if existed { [] } else { child_route.tags }
	routes = List.map(
		updated.routes,
		|route| if route.segments == segments { { ..route, tags: own_tags, router_layers: [], inner_layers: own } } else { route },
	)
	{ ..updated, routes }
}

## Adds a child's fallbacks under `mount_prefix`, wrapped as the child had them.
add_fallbacks = |router, mount_prefix, fallbacks| {
	var $fallbacks = router.fallbacks
	for fallback in fallbacks {
		prefix = List.concat(mount_prefix, fallback.prefix)
		if List.any($fallbacks, |existing| existing.prefix == prefix) { return Err(DuplicateFallback) }
		$fallbacks = List.append($fallbacks, { ..fallback, prefix, router_layers: [], inner_layers: flat_layers(fallback) })
	}
	Ok({ ..router, fallbacks: $fallbacks })
}

nest_routes = |parent, prefix, child_routes| nest_routes_help(parent, prefix, child_routes, 0)

nest_routes_help = |router, prefix, routes, index|
	if index == List.len(routes) {
		Ok({ ..router, nodes: build_nodes(router.routes) })
	} else {
		route = list_get(routes, index)
		segments = combine_nested_segments(prefix.segments, route.segments)
		updated = nest_route_endpoints(router, segments, prefix.param_names, route.endpoints, 0)?
		nest_routes_help(with_child_path_layers(updated, router, route, segments), prefix, routes, index + 1)
	}

nest_route_endpoints = |router, segments, prefix_names, endpoints, index|
	if index == List.len(endpoints) {
		Ok(router)
	} else {
		endpoint = list_get(endpoints, index)
		names = List.concat(prefix_names, endpoint.param_names)
		if has_duplicate_name(names) { return Err(DuplicateParameter("nested route")) }
		parsed = { segments, param_names: names, asterisk: segments == [Asterisk] }
		updated = add_route(router, "nested route", parsed, [(endpoint.method, { layers: flat_layers(endpoint), handler: endpoint.handler, tags: endpoint.tags })])?
		nest_route_endpoints(updated, segments, prefix_names, endpoints, index + 1)
	}

combine_nested_segments = |prefix, child|
	if child == [Asterisk] { child }
	else if child == [Static("")] { prefix }
	else if prefix == [Static("")] { child }
	else { List.concat(prefix, child) }

ends_with_empty_segment = |segments|
	List.len(segments) > 1 and List.last(segments) == Ok(Static(""))

has_duplicate_name = |names| {
	var $outer = 0
	while $outer < List.len(names) {
		var $inner = $outer + 1
		while $inner < List.len(names) {
			if list_get(names, $outer) == list_get(names, $inner) { return Bool.True }
			$inner = $inner + 1
		}
		$outer = $outer + 1
	}
	Bool.False
}

empty_node = {
	static_edges: [],
	static_index: Dict.empty(),
	param_child: None,
	catch_child: None,
	asterisk_child: None,
	endpoints: [],
	path_tags: [],
	path_layers: [],
}

## The trie for `routes`, after a change to their layers.
build_nodes = |routes| {
	var $nodes = [empty_node]
	for route in routes {
		$nodes = insert_endpoints($nodes, route.segments, route.endpoints, route.tags, flat_layers(route))
	}
	$nodes
}

## The trie keeps each endpoint's layers already flattened into
## `inner_layers`, so a request does not join them again.
insert_endpoints = |nodes, segments, endpoints, path_tags, path_layers| {
	var $nodes = nodes
	for endpoint in endpoints {
		$nodes = trie_insert($nodes, segments, { ..endpoint, router_layers: [], inner_layers: flat_layers(endpoint) }, path_tags, path_layers)
	}
	$nodes
}

trie_insert = |nodes, segments, endpoint, path_tags, path_layers| {
	var $nodes = nodes
	var $node_index = 0
	var $segment_index = 0
	while $segment_index < List.len(segments) {
		node = list_get($nodes, $node_index)
		segment = list_get(segments, $segment_index)
		child = match segment {
			Static(value) => find_static_child(node, value)
			Param => node.param_child
			CatchAll => node.catch_child
			Asterisk => node.asterisk_child
		}
		$node_index = match child {
			Some(existing) => existing
			None => {
				new_index = List.len($nodes)
				$nodes = List.append($nodes, empty_node)
				updated_node = match segment {
					Static(value) => { ..node, static_edges: List.append(node.static_edges, { value, child: new_index }), static_index: Dict.insert(node.static_index, value, new_index) }
					Param => { ..node, param_child: Some(new_index) }
					CatchAll => { ..node, catch_child: Some(new_index) }
					Asterisk => { ..node, asterisk_child: Some(new_index) }
				}
				$nodes = list_set($nodes, $node_index, updated_node)
				new_index
			}
		}
		$segment_index = $segment_index + 1
	}
	leaf = list_get($nodes, $node_index)
	list_set($nodes, $node_index, { ..leaf, endpoints: List.append(leaf.endpoints, endpoint), path_tags, path_layers })
}

linear_static_edges = 8

find_static_child = |node, value|
	if List.len(node.static_edges) <= linear_static_edges {
		for edge in node.static_edges {
			if edge.value == value { return Some(edge.child) }
		}
		None
	} else {
		match Dict.get(node.static_index, value) {
			Ok(child) => Some(child)
			Err(_) => None
		}
	}

## The request target as the router matches it: the asterisk form, or the
## path split into its raw segments.
split_target = |path|
	if path == "*" {
		AsteriskTarget
	} else {
		PathTarget(List.drop_first(Str.split_on(path, "/"), 1))
	}

trie_best_match = |nodes, target|
	match target {
		AsteriskTarget =>
			match (list_get(nodes, 0)).asterisk_child {
				None => NoMatch
				Some(child) => Matched(list_get(nodes, child), [])
			}
		PathTarget(path) =>
			match trie_match_node(nodes, 0, path, 0, []) {
				NoTrieMatch => NoMatch
				TrieMatch(node_index, captures) => Matched(list_get(nodes, node_index), captures)
			}
	}

trie_match_node = |nodes, node_index, path, path_index, captures| {
	node = list_get(nodes, node_index)
	if path_index == List.len(path) {
		if List.is_empty(node.endpoints) { NoTrieMatch } else { TrieMatch(node_index, captures) }
	} else {
		segment = list_get(path, path_index)
		match find_static_child(node, normalize_segment(segment)) {
			None => {}
			Some(child) => {
				candidate = trie_match_node(nodes, child, path, path_index + 1, captures)
				match candidate {
					TrieMatch(_, _) => return candidate
					NoTrieMatch => {}
				}
			}
		}
		if !Str.is_empty(segment) {
			match node.param_child {
				None => {}
				Some(child) => {
					candidate = trie_match_node(nodes, child, path, path_index + 1, List.append(captures, segment))
					match candidate {
						TrieMatch(_, _) => return candidate
						NoTrieMatch => {}
					}
				}
			}
		}
		match node.catch_child {
			None => {}
			Some(child) => {
				rest = Str.join_with(List.drop_first(path, path_index), "/")
				if !Str.is_empty(rest) {
					candidate = trie_match_node(nodes, child, path, List.len(path), List.append(captures, rest))
					match candidate {
						TrieMatch(_, _) => return candidate
						NoTrieMatch => {}
					}
				}
			}
		}
		NoTrieMatch
	}
}

dispatch_router! = |router, initial, model, request| {
	head = RequestHead.from_request(request, Instant.now!({}), initial)
	reply = match before_routing!(router.before_routing_checks, model, head) {
		Err(answer) => answer
		# With no check, `routed` is the head just made from `request`.
		Ok(routed) => dispatch_routed!(router, model, routed, if List.is_empty(router.before_routing_checks) { request } else { RequestHead.apply(routed, request) })
	}
	{ response: Respond.to_response(reply), route: Reply.route(reply), reply }
}

before_routing! = |checks, model, head| {
	var $head = head
	for check! in checks {
		$head = check!(model, $head)?
	}
	Ok($head)
}

## Finds the route for the (possibly changed) request and runs it inside its
## layers. A 405 or a bad parameter runs only the path's layers; a missing path
## runs only its fallback's.
dispatch_routed! = |router, model, head, request|
	match trie_best_match(router.nodes, split_target(request.path)) {
		NoMatch =>
			match fallback_for(router.fallbacks, request.path) {
				None => Pipeline.without_body!(router.default_layers, model, { ..head, tags: router.default_tags }, |_ready| Reply.full(empty_response(404, [])))
				Some(fallback) =>
					Pipeline.without_body!(
						flat_layers(fallback),
						model,
						{ ..head, tags: fallback.tags },
						|ready| Reply.with_route(answer_with!(fallback, Router.Unmatched.NotFound, model, ready), "fallback"),
					)
			}
		Matched(node, captures) =>
			match select_endpoint(node.endpoints, request.method) {
				None =>
					Pipeline.without_body!(
						node.path_layers,
						model,
						{ ..head, tags: node.path_tags },
						|ready| not_allowed!(router.fallbacks, node.endpoints, model, ready),
					)
				Some(endpoint) =>
					match decode_params(endpoint.param_names, captures) {
						Err(_) =>
							Pipeline.without_body!(
								node.path_layers,
								model,
								{ ..head, tags: node.path_tags },
								|ready| Reply.with_route(bad_path!(router.fallbacks, model, ready), endpoint.route),
							)
						Ok(path_params) =>
							Pipeline.run!(endpoint.inner_layers, 0, endpoint.handler, model, { ..head, path_params, tags: endpoint.tags }, request, |reply| Reply.with_route(reply, endpoint.route))
					}
			}
	}

answer_with! = |fallback, reason, model, head|
	match (fallback.answer!)(reason, model, head) {
		Ok(reply) | Err(reply) => reply
	}

not_allowed! = |fallbacks, endpoints, model, head|
	match fallback_for(fallbacks, head.path) {
		None => Reply.full(method_not_allowed(endpoints))
		Some(fallback) => {
			reply = answer_with!(fallback, Router.Unmatched.MethodNotAllowed(allowed_methods(endpoints)), model, head)
			with_allow(reply, endpoints)
		}
	}

bad_path! = |fallbacks, model, head|
	match fallback_for(fallbacks, head.path) {
		None => Reply.full(empty_response(400, []))
		Some(fallback) => answer_with!(fallback, Router.Unmatched.BadPath, model, head)
	}

## RFC 9110 requires `Allow` on a 405; a fallback that left it out gets it.
with_allow = |reply, endpoints| {
	response = Respond.to_response(reply)
	has_allow = List.any(response.headers, |header| header.name == Http.HeaderName.("allow"))
	if response.status == 405 and !has_allow {
		Reply.with_headers(reply, (method_not_allowed(endpoints)).headers)
	} else {
		reply
	}
}

## The fallback with the longest prefix that the path is under.
fallback_for = |fallbacks, path| {
	parts = match split_target(path) {
		PathTarget(segments) => segments
		AsteriskTarget => []
	}
	var $best = None
	var $best_length = 0
	for fallback in fallbacks {
		length = List.len(fallback.prefix)
		better = match $best {
			None => Bool.True
			Some(_) => length > $best_length
		}
		if better and prefix_matches(fallback.prefix, parts) {
			$best = Some(fallback)
			$best_length = length
		}
	}
	$best
}

prefix_matches = |prefix, parts| {
	if List.len(prefix) > List.len(parts) { return Bool.False }
	var $index = 0
	for segment in prefix {
		part = list_get(parts, $index)
		matched = match segment {
			Static(value) => normalize_segment(part) == value
			Param => !Str.is_empty(part)
			CatchAll | Asterisk => Bool.False
		}
		if !matched { return Bool.False }
		$index = $index + 1
	}
	Bool.True
}

probe_router = |router, method, path| {
	match trie_best_match(router.nodes, split_target(path)) {
		NoMatch => RouteProbe.NotFound
		Matched(node, captures) => {
			match select_endpoint(node.endpoints, method) {
				None => RouteProbe.MethodNotAllowed(allow_value(node.endpoints))
				Some(endpoint) =>
					match decode_params(endpoint.param_names, captures) {
						Ok(params) => RouteProbe.Found(params)
						Err(_) => RouteProbe.BadPathParams
					}
			}
		}
	}
}

## The endpoint for `method`, with HEAD falling back to GET.
select_endpoint = |endpoints, method|
	match find_endpoint(endpoints, method) {
		Some(endpoint) => Some(endpoint)
		None => if method == Http.Method.HEAD { find_endpoint(endpoints, Http.Method.GET) } else { None }
	}

find_endpoint = |endpoints, method| {
	for endpoint in endpoints {
		if endpoint.method == method { return Some(endpoint) }
	}
	None
}

decode_params = |names, captures| {
	var $params = []
	var $index = 0
	while $index < List.len(names) {
		decoded = percent_decode(list_get(captures, $index))?
		if !is_safe_param(decoded) { return Err(UnsafeParam) }
		$params = List.append($params, PathParam.{ name: list_get(names, $index), value: decoded })
		$index = $index + 1
	}
	Ok($params)
}

percent_decode = |value| {
	bytes = Str.to_utf8(value)
	var $decoded = []
	var $index = 0
	while $index < List.len(bytes) {
		byte = list_get(bytes, $index)
		if byte == 37 {
			if $index + 2 >= List.len(bytes) { return Err(InvalidPercentEncoding) }
			high = hex_value(list_get(bytes, $index + 1))?
			low = hex_value(list_get(bytes, $index + 2))?
			$decoded = List.append($decoded, high * 16 + low)
			$index = $index + 3
		} else {
			$decoded = List.append($decoded, byte)
			$index = $index + 1
		}
	}
	match Str.from_utf8($decoded) {
		Ok(text) => Ok(text)
		Err(_) => Err(InvalidUtf8)
	}
}

## A decoded value a handler can join under a base directory: no NUL, and
## once split on `/`, no `.` or `..` segment and no empty segment except a
## trailing one. A leading `/` (from `%2F`) would make the value an absolute
## path, which many path joins put in place of the base.
is_safe_param = |value| {
	parts = Str.split_on(value, "/")
	!List.contains(Str.to_utf8(value), 0)
		and !List.any(parts, |part| part == "." or part == "..")
		and !List.any(List.drop_last(parts, 1), Str.is_empty)
}

## Rewrites percent-encoding to one form so a static segment matches every
## request segment that decodes to it, as a parameter would see it
## (`decode_params`): escapes are decoded, except `%2F` and `%25`, which stay
## escapes in uppercase hex so `%2F` never splits a segment. Bytes that do not
## form an escape are kept. A segment that does not decode to UTF-8 is kept
## as it is; a parameter would reject it.
normalize_segment = |segment| {
	bytes = Str.to_utf8(segment)
	if !List.contains(bytes, '%') { return segment }
	var $output = []
	var $index = 0
	while $index < List.len(bytes) {
		byte = list_get(bytes, $index)
		escape = if byte == '%' and $index + 2 < List.len(bytes) {
			match (hex_value(list_get(bytes, $index + 1)), hex_value(list_get(bytes, $index + 2))) {
				(Ok(high), Ok(low)) => Escape(high, low)
				_ => NotEscape
			}
		} else {
			NotEscape
		}
		match escape {
			Escape(high, low) => {
				value = high * 16 + low
				$output = if value == '/' or value == '%' {
					List.concat($output, ['%', PercentEncoding.hex_digit(high), PercentEncoding.hex_digit(low)])
				} else {
					List.append($output, value)
				}
				$index = $index + 3
			}
			NotEscape => {
				$output = List.append($output, byte)
				$index = $index + 1
			}
		}
	}
	match Str.from_utf8($output) {
		Ok(text) => text
		Err(_) => segment
	}
}

hex_value = |byte|
	if byte >= 48 and byte <= 57 { Ok(byte - 48) }
	else if byte >= 65 and byte <= 70 { Ok(byte - 55) }
	else if byte >= 97 and byte <= 102 { Ok(byte - 87) }
	else { Err(InvalidHex) }

method_not_allowed = |endpoints| {
	allow = allow_value(endpoints)
	value = match HeaderValue.from_str(allow) {
		Ok(header_value) => header_value
		Err(CrlfInjection) => { crash "generated Allow header contained CR or LF" }
	}
	empty_response(405, [Http.ResponseHeader.{ name: Http.HeaderName.("allow"), value }])
}

allow_value = |endpoints| Str.join_with(List.map(allowed_methods(endpoints), Http.Method.to_str), ", ")

## The methods of a path in the order `Allow` lists them. GET implies HEAD.
allowed_methods = |endpoints| {
	ordered = [Http.Method.OPTIONS, Http.Method.GET, Http.Method.HEAD, Http.Method.POST, Http.Method.PUT, Http.Method.DELETE, Http.Method.PATCH, Http.Method.QUERY]
	List.keep_if(
		ordered,
		|method| {
			has_method = List.any(endpoints, |endpoint| endpoint.method == method)
			get_implies_head = method == Http.Method.HEAD and List.any(endpoints, |endpoint| endpoint.method == Http.Method.GET)
			has_method or get_implies_head
		},
	)
}

empty_response = |status, headers| Http.Response.{ status, headers, body: Http.ResponseBody.Empty }

list_get = |items, index|
	match List.get(items, index) {
		Ok(value) => value
		Err(_) => crash "roxum Router internal list index invariant"
	}

list_set = |items, index, value|
	match List.set(items, index, value) {
		Ok(updated) => updated
		Err(_) => crash "roxum Router internal list index invariant"
	}

error_message = |error|
	match error {
		InvalidPattern(pattern) => "roxum Router: invalid route pattern `${pattern}`"
		CatchAllMustBeLast(pattern) => "roxum Router: catch-all must be the final segment in `${pattern}`"
		DuplicateParameter(name) => "roxum Router: duplicate path parameter `${name}`"
		DuplicateRoute(pattern) => "roxum Router: duplicate method and structural route `${pattern}`"
		InvalidAsteriskMethod => "roxum Router: `*` is only valid for OPTIONS"
		CatchAllInNestPrefix => "roxum Router: a nest prefix cannot contain a catch-all"
		DuplicateFallback => "roxum Router: two custom fallbacks answer for the same paths"
		MergedFallback => "roxum Router: the right router in a merge cannot have its own fallback"
		NestedBeforeRouting => "roxum Router: a nested router cannot have before_routing checks"
		MergedBeforeRouting => "roxum Router: the right router in a merge cannot have before_routing checks"
	}

expect match parse_pattern("/users/{id}") {
	Ok({ segments: [Static("users"), Param], param_names: ["id"], .. }) => Bool.True
	_ => Bool.False
}

expect match parse_pattern("/files/{*rest}/more") {
	Err(CatchAllMustBeLast(_)) => Bool.True
	_ => Bool.False
}

expect match parse_pattern("/{id}/{id}") {
	Err(DuplicateParameter("id")) => Bool.True
	_ => Bool.False
}

expect match parse_pattern("/{9bad}") {
	Err(InvalidPattern(_)) => Bool.True
	_ => Bool.False
}


expect percent_decode("a%2Fb") == Ok("a/b")
expect percent_decode("%E9%B5%AC") == Ok("鵬")
expect match percent_decode("%FF") {
	Err(InvalidUtf8) => Bool.True
	_ => Bool.False
}
expect match percent_decode("%2") {
	Err(InvalidPercentEncoding) => Bool.True
	_ => Bool.False
}
expect match percent_decode("%2G") {
	Err(InvalidHex) => Bool.True
	_ => Bool.False
}

expect normalize_segment("admin") == "admin"
expect normalize_segment("%61dmin") == "admin"
expect normalize_segment("%7e%2D%2e%5F") == "~-._"
expect normalize_segment("%c3%a9") == "é"
expect normalize_segment("%40me") == "@me"
expect normalize_segment("a%3Ab") == "a:b"
expect normalize_segment("a%2fb") == "a%2Fb"
expect normalize_segment("100%25") == "100%25"
# A segment that is not UTF-8 once decoded is kept.
expect normalize_segment("%ff") == "%ff"
# Bytes that do not form an escape are kept, at the end and with bad hex.
expect normalize_segment("50%") == "50%"
expect normalize_segment("5%2") == "5%2"
expect normalize_segment("a%zz") == "a%zz"

expect is_safe_param("a.b")
expect is_safe_param("..a/b..")
expect !is_safe_param(".")
expect !is_safe_param("..")
expect !is_safe_param("a/../b")
expect !is_safe_param("a\u(0)")
# A leading `/` or an empty segment inside; a trailing `/` is kept.
expect !is_safe_param("/etc")
expect !is_safe_param("a//b")
expect is_safe_param("a/")
expect is_safe_param("a/b")

probe_handler = Handler.static(|{}| Reply.empty)

probe_routes =
	Router.new
		.route("/admin", MethodRouter.get(probe_handler))
		.route("/{page}", MethodRouter.get(probe_handler))
		.route("/files/{*rest}", MethodRouter.get(probe_handler))
		.route("/users/@me", MethodRouter.get(probe_handler))
		.route("/users/{id}", MethodRouter.get(probe_handler))
		.route("/*", MethodRouter.get(probe_handler))
		.route("*", MethodRouter.options(probe_handler))

# An encoded alias reaches the static route (and its layers), not the parameter.
expect Router.probe(probe_routes, Http.Method.GET, "/admin") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.GET, "/%61dmin") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.GET, "/%41dmin") == RouteProbe.Found([PathParam.{ name: "page", value: "Admin" }])
expect Router.probe(probe_routes, Http.Method.GET, "/a%2Fb") == RouteProbe.Found([PathParam.{ name: "page", value: "a/b" }])
# Reserved characters too: `%40me` is the static `@me`, not `{id}`.
expect Router.probe(probe_routes, Http.Method.GET, "/users/@me") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.GET, "/users/%40me") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.GET, "/users/%40you") == RouteProbe.Found([PathParam.{ name: "id", value: "@you" }])

# A decoded capture is never a traversal step or NUL.
expect Router.probe(probe_routes, Http.Method.GET, "/%2e") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/%2e%2e") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/files/..%2Fetc") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/files/a%00") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/files/a.b/c") == RouteProbe.Found([PathParam.{ name: "rest", value: "a.b/c" }])
expect Router.probe(probe_routes, Http.Method.GET, "/files/%2Fetc%2Fpasswd") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/files/a%2F%2Fb") == RouteProbe.BadPathParams
expect Router.probe(probe_routes, Http.Method.GET, "/files/a%2F") == RouteProbe.Found([PathParam.{ name: "rest", value: "a/" }])

# The asterisk form and the literal `/*` path are different routes.
expect Router.probe(probe_routes, Http.Method.OPTIONS, "*") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.GET, "/*") == RouteProbe.Found([])
expect Router.probe(probe_routes, Http.Method.OPTIONS, "/*") == RouteProbe.MethodNotAllowed("GET, HEAD")

expect match parse_pattern("/a/..") {
	Err(InvalidPattern(_)) => Bool.True
	_ => Bool.False
}

expect match Router.try_merge(Router.new, Router.new.route("/*", MethodRouter.get(probe_handler))) {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}

expect match Router.try_nest(Router.new, "/api/", Router.new.route("/users", MethodRouter.get(probe_handler))) {
	Err(InvalidPattern("/api/")) => Bool.True
	_ => Bool.False
}

expect match Router.try_nest(Router.new, "/api", Router.new.route("/users", MethodRouter.get(probe_handler))) {
	Ok(nested) => Router.probe(nested, Http.Method.GET, "/api/users") == RouteProbe.Found([])
	Err(_) => Bool.False
}

# Matching through the trie: a catch-all spans segments, a parameter needs a
# non-empty segment, and a trailing slash is a different path.
expect Router.probe(probe_routes, Http.Method.GET, "/files/a/b") == RouteProbe.Found([PathParam.{ name: "rest", value: "a/b" }])
expect Router.probe(probe_routes, Http.Method.GET, "/admin/") == RouteProbe.NotFound
expect Router.probe(probe_routes, Http.Method.HEAD, "/admin") == RouteProbe.Found([])

# A route reads back as its pattern: the root, a trailing slash, parameters, a
# catch-all, and the asterisk form; static segments in the normalized form.
rendered = |pattern|
	match parse_pattern(pattern) {
		Ok(parsed) => render_route(parsed.segments, parsed.param_names)
		Err(_) => "invalid"
	}

expect rendered("/") == "/"
expect rendered("/users") == "/users"
expect rendered("/users/") == "/users/"
expect rendered("/users/{id}/posts/{post_id}") == "/users/{id}/posts/{post_id}"
expect rendered("/files/{*rest}") == "/files/{*rest}"
expect rendered("*") == "*"
expect rendered("/%61dmin/%2f") == "/admin/%2F"

# A nested route reads as one pattern, prefix parameters first; a child `/`
# is the prefix itself.
expect match (parse_pattern("/api/{tenant}"), parse_pattern("/users/{id}"), parse_pattern("/")) {
	(Ok(prefix), Ok(child), Ok(root)) =>
		render_route(combine_nested_segments(prefix.segments, child.segments), List.concat(prefix.param_names, child.param_names)) == "/api/{tenant}/users/{id}"
			and render_route(combine_nested_segments(prefix.segments, root.segments), prefix.param_names) == "/api/{tenant}"
	_ => Bool.False
}

# Each pattern is listed once, though it has several methods; a custom
# fallback is listed as `fallback`.
expect Router.route_patterns(Router.new) == []
expect
	Router.new
		.route("/users/{id}", MethodRouter.get(probe_handler))
		.route("/users/{id}", MethodRouter.post(probe_handler))
		.route("/", MethodRouter.get(probe_handler))
		.route_patterns()
		== ["/users/{id}", "/"]
expect
	Router.new
		.nest("/api/{tenant}", Router.new.route("/items", MethodRouter.get(probe_handler)))
		.fallback(|_reason, _model, _head| Ok(Reply.empty))
		.route_patterns()
		== ["/api/{tenant}/items", "fallback"]

# Static siblings are searched linearly up to `linear_static_edges` and through
# the index above it; 8 and 9 siblings take each path. Either way the first and
# last sibling match, and a missing value still reaches the parameter sibling.
siblings_routes : U64 -> _
siblings_routes = |count| {
	var $router = Router.new.route("/{page}", MethodRouter.get(probe_handler))
	var $index = 0
	while $index < count {
		$router = Router.route($router, "/s${$index.to_str()}", MethodRouter.get(probe_handler))
		$index = $index + 1
	}
	$router
}
expect Router.probe(siblings_routes(8), Http.Method.GET, "/s0") == RouteProbe.Found([])
expect Router.probe(siblings_routes(8), Http.Method.GET, "/s7") == RouteProbe.Found([])
expect Router.probe(siblings_routes(8), Http.Method.GET, "/s8") == RouteProbe.Found([PathParam.{ name: "page", value: "s8" }])
expect Router.probe(siblings_routes(9), Http.Method.GET, "/s0") == RouteProbe.Found([])
expect Router.probe(siblings_routes(9), Http.Method.GET, "/s8") == RouteProbe.Found([])
expect Router.probe(siblings_routes(9), Http.Method.GET, "/s9") == RouteProbe.Found([PathParam.{ name: "page", value: "s9" }])
expect Router.probe(siblings_routes(9), Http.Method.GET, "/%73%38") == RouteProbe.Found([])
