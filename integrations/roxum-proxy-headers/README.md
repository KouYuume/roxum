# roxum-proxy-headers

`roxum-proxy-headers` recovers the client address behind a reverse proxy or load balancer. It reads
`X-Forwarded-For` and `X-Forwarded-Proto` only when the direct peer is a proxy you trust.

```roc
import proxy_headers.ProxyHeaders

routes =
	routes_without_proxy_headers
		.before_routing(ProxyHeaders.trust(["10.0.0.0/16"]))
```

Pass it to `Router.before_routing` so every route and response sees the same address. List the proxies as
addresses or CIDR ranges. Behind AWS ALB, whose addresses change, list the load balancer's subnets or the VPC CIDR.

## Behavior

- **Trusted peer**: the `X-Forwarded-For` chain, including repeated fields, is read from the nearest hop. Trusted
  proxies are skipped, and the first untrusted address becomes `request.remote_addr` with port `0`, because the
  chain carries no client port. If every hop is trusted, the farthest one is used. Addresses written as `[v6]`,
  `[v6]:port`, or `v4:port` are accepted. The `X-Forwarded-For` fields are then removed, because the start of the chain
  may be values the client wrote; read the address from `remote_addr`. Other fields from the proxy, such as
  `X-Forwarded-Proto` and `X-Forwarded-Host`, are kept.
- **Untrusted peer**: every forwarding field (`X-Forwarded-*`, `X-Real-IP`, and `Forwarded`) is removed from the
  request, so handlers never read a value a client chose. The address stays the peer's.
- **Unparsable chain from a trusted peer**: the address stays the peer's and every forwarding field is removed.
- `ProxyHeaders.scheme(request)` returns `Https` when the nearest `X-Forwarded-Proto` value is `https`, and `Http`
  otherwise. Call it after `trust` ran; from an untrusted peer the field has already been removed.

`ProxyHeaders.try_trust` returns `Err(InvalidProxy(entry))` for an entry that is not an address or CIDR range, or that
is a `/0` range (which would trust every client);
`ProxyHeaders.trust` crashes instead, so a mistake in constant routes fails when the app is built.

Only `X-Forwarded-For` and `X-Forwarded-Proto` are read. The RFC 7239 `Forwarded` field is removed from untrusted
peers but not parsed, and the PROXY protocol is not supported.

## Security

Trust only the addresses your proxies actually connect from. A range that includes clients lets them set their own
address. Proxies must append to `X-Forwarded-For` rather than pass a client's value through unchanged; nginx's
`$proxy_add_x_forwarded_for` and AWS ALB both do.
