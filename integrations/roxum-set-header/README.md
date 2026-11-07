# roxum-set-header

`roxum-set-header` provides a pure middleware factory that appends one fixed response field to both successful and
error replies. Apply it with `MethodRouter.layer` for one method handler, or `Router.layer` for the routes written above
it, including their 400 and 405 responses, and the router's 404.

```roc
import pf.HeaderName
import pf.HeaderValue
import set_header.SetHeader

value : HeaderValue
value = "public"
layer = SetHeader.layer(HeaderName.("x-content-policy"), value)
routes = Router.layer(routes_without_policy, layer)
```

`SetHeader.layer` preserves existing fields and appends its field line; it does not replace or deduplicate fields with
the same name. Use it only where repeated field lines have the intended HTTP semantics. `SetHeader.replace` takes the
same arguments and first removes any field of the same name (compared without regard to case), so the response carries
exactly one. The host continues to reject
application-provided framing fields such as `Content-Length` and `Transfer-Encoding`.

Header values use roxum's `HeaderValue` type, so runtime values must pass `HeaderValue.from_str` and cannot contain
CR or LF.
