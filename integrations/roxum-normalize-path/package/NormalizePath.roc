import pf.Reply
import pf.RequestHead

NormalizePath := [].{
	## Removes trailing slashes from the request path before routing, so
	## `/users/` reaches the `/users` route. Pass it to `Router.before_routing`,
	## which runs before the route is found. The root path `/` and `raw_target`
	## are left unchanged. A function of `{}` because a value cannot be generic
	## over `model`.
	trim : {} -> (model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply))
	trim = |{}| |_model, head| Ok({ ..head, path: NormalizePath.trim_trailing_slash(head.path) })

	trim_trailing_slash : Str -> Str
	trim_trailing_slash = |path| {
		var $trimmed = path
		while $trimmed != "/" and Str.ends_with($trimmed, "/") {
			$trimmed = Str.drop_suffix($trimmed, "/")
		}
		$trimmed
	}
}

# The root is the only path that keeps its slash.
expect NormalizePath.trim_trailing_slash("/") == "/"
expect NormalizePath.trim_trailing_slash("/users") == "/users"
expect NormalizePath.trim_trailing_slash("/users/") == "/users"
expect NormalizePath.trim_trailing_slash("/users/1/") == "/users/1"

# The host rejects `//`, but a middleware may build any path; repeated
# trailing slashes still collapse, and an all-slash path becomes the root.
expect NormalizePath.trim_trailing_slash("/users//") == "/users"
expect NormalizePath.trim_trailing_slash("//") == "/"

# Paths without a leading slash are left as they are.
expect NormalizePath.trim_trailing_slash("*") == "*"
expect NormalizePath.trim_trailing_slash("") == ""
