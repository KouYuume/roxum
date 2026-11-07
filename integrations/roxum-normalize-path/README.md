# roxum-normalize-path

`roxum-normalize-path` removes trailing slashes from the request path before routing, so `/users/` reaches the
`/users` route. The root path `/` is unchanged.

```roc
import normalize_path.NormalizePath

routes = Router.before_routing(routes_without_normalization, NormalizePath.trim({}))
```

Pass it to `Router.before_routing`, which runs before route matching, so the rewritten path decides the route, the
method check, and the 404 response. A layer runs after routing and cannot change the match.

- The path is rewritten in place; the client is not redirected.
- The query and `raw_target` are unchanged. `raw_target` keeps the path the client sent.
- The host already rejects `//`, `.`, and `..` segments with 400 before Roc runs, so trailing slashes are the only
  normalization left to this layer.
