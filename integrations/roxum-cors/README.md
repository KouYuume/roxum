# roxum-cors

`roxum-cors` answers CORS preflight requests and adds CORS fields to responses for allowed origins.

```roc
import cors.Cors

routes =
	routes_without_cors
		.layer(
			Cors.layer(
				{
					..Cors.defaults,
					origins: Exact(["https://app.example"]),
					methods: [GET, POST],
					headers: [HeaderName.("content-type")],
					credentials: Bool.True,
					max_age_seconds: Value(600),
				},
			),
		)
```

Apply it with `Router.layer`. Preflight requests use `OPTIONS`, which a `MethodRouter.layer` never sees because routing
answers 405 first.

## Configuration

| Field | Meaning |
|---|---|
| `origins` | `Exact(list)` compares the whole serialized origin, case-sensitively. `Any` allows every origin. |
| `methods` | Sent as `Access-Control-Allow-Methods` on preflight responses. |
| `headers` | Sent as `Access-Control-Allow-Headers` on preflight responses; omitted when empty. |
| `expose_headers` | Sent as `Access-Control-Expose-Headers` on other responses; omitted when empty. |
| `credentials` | Sends `Access-Control-Allow-Credentials: true`. |
| `max_age_seconds` | Sent as `Access-Control-Max-Age` on preflight responses; `None` omits it. |

`Cors.defaults` allows no origin, the methods `GET`, `HEAD`, and `POST`, no extra headers, and no credentials.

`Cors.try_layer` validates the configuration and returns an error; `Cors.layer` crashes instead. Because routes are
usually constants, a `Cors.layer` configuration error is reported when the app is built. Errors are:

- `CredentialsWithAnyOrigin`: browsers reject credentials with `Access-Control-Allow-Origin: *`
- `InvalidOrigin` and `InvalidHeaderName`: a value contains CR or LF

## Behavior

- A request is cross-origin only when it has exactly one `Origin` field. Repeated fields are treated as absent.
- A preflight request is `OPTIONS` with `Origin` and `Access-Control-Request-Method`. The layer answers 204 without
  calling the handler or routing, so it also answers for paths that do not exist. For an origin that is not allowed,
  the 204 carries no CORS fields and the browser rejects the request.
- The layer does not check the requested method and headers against the configuration; it sends the configured lists
  and leaves the decision to the browser.
- Other responses to an allowed origin, including errors and synthetic 404 / 405, get `Access-Control-Allow-Origin`,
  credentials, and exposed headers.
- With `Exact` origins every response carries `Vary: Origin`, so shared caches do not mix responses between origins.
  With `Any` the origin is sent as `*` and no `Vary` is added.
- The `access-control-*` fields replace any the handler already added, so each appears once. `Vary: Origin` is
  appended, because `Vary` lists every field the response depends on.
