# Running behind a reverse proxy

Terminate inbound TLS at a reverse proxy or load balancer. The configurations below connect to roxum over IPv4 HTTP/1.1. For explicit
cleartext HTTP/2 upstreams and their current limits, see [deployment](deployment.md#opt-in-http2). Outbound PostgreSQL and HTTP connections can use TLS; see [database](database.md) and [HTTP client](http-client.md).

## Keep-alive

Set roxum's keep-alive idle timeout longer than the proxy's upstream idle timeout. Otherwise, the proxy can reuse a connection just as roxum closes it, causing a failed request. For a proxy configured with a 60-second upstream timeout, use a longer value such as 75 seconds:

```roc
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 8080 }),
		timeouts: {
			..Server.Timeouts.defaults,
			keep_alive_idle_milliseconds: 75_000,
		},
		limits: Server.Limits.defaults,
	},
})
```

Adjust both sides together when changing timeouts. roxum's default is 15 seconds.

## Forwarded client addresses

Use [roxum-proxy-headers](../../integrations/roxum-proxy-headers/README.md) before routing. Trust only the addresses from which the proxy actually connects:

```roc
routes =
	routes_without_proxy_headers
		.before_routing(ProxyHeaders.trust(["10.0.0.0/16"]))
```

The integration removes forwarding fields from untrusted peers. For a trusted peer it resolves `X-Forwarded-For` into `remote_addr` and removes that field. A `/0` trust range is rejected. Trusting a range that includes direct clients allows address spoofing. The proxy must append the client address it observed; nginx can use `$proxy_add_x_forwarded_for`.

## Example proxy configurations

Match body limits to the application's routes and disable response buffering for SSE and other streaming endpoints.

### nginx

```nginx
upstream roxum {
    server 127.0.0.1:8080;
    keepalive 32;
    keepalive_timeout 60s;
}

server {
    listen 443 ssl;
    http2 on;
    server_name example.com;
    ssl_certificate     /etc/ssl/example.com.crt;
    ssl_certificate_key /etc/ssl/example.com.key;

    client_max_body_size 2m;

    location / {
        proxy_pass http://roxum;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /events {
        proxy_pass http://roxum;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
}
```

### Caddy

```caddyfile
example.com {
    reverse_proxy 127.0.0.1:8080 {
        transport http {
            keepalive 2m
        }
    }
}
```

For a load balancer, configure an HTTPS listener and an HTTP target pointing to roxum. Use a health-check route that returns 200 without depending on external services. Keep the backend network private; the proxy-to-roxum connection is plaintext.

## Server behavior

- Bind to `127.0.0.1` when only a proxy on the same host should connect.
- Request heads are limited to 32 KiB. Buffered bodies default to 2 MiB; streaming bodies have no default size limit. Configure `Server.Limits` and route `BodyLimit` values deliberately.
- A handler crash before sending the head returns 500 and closes the connection. A crash after a streaming head closes without another status line.
- An initialization crash terminates the worker and drops its connections. Restrict proxy retries to requests safe to repeat.
- HTTP/2 or HTTP/3 may be used between clients and the proxy; the backend connection in these configurations remains HTTP/1.1.
