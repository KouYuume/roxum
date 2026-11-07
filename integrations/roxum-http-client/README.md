# roxum-http-client

An HTTP/1.1 client written in Roc over roxum's `Tcp`: the host keeps the connections, and the protocol (requests,
responses, redirects) is Roc. Waiting for a server suspends only the request; its thread serves other requests
meanwhile. Requests and responses are [roc-lang/http](https://github.com/roc-lang/http)'s `Request` and `Response`.

```roc
app [program] {
	pf: platform "../../platform/main.roc",
	hc: "../../integrations/roxum-http-client/package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import hc.HttpClient
import http.Method
import http.Request

# In init!: one client, kept in the model.
client = HttpClient.client!(HttpClient.Config.{})?

# In a handler:
request = Request.from_method(Method.GET).with_uri("https://tax.example.com/rates/JP")
response = HttpClient.send_with!(model.client, request, HttpClient.SendOptions.{
	secret_headers: [{ name: "Authorization", prefix: "Bearer ", secret: model.tax_token }],
})?
```

The app names roc-lang/http by the same URL as this package, so that both use the same `Request` and `Response`.

## Settings

`HttpClient.Config`: `timeout_milliseconds` (30 s, the whole exchange including redirects; a request's
`with_timeout` takes precedence), `maximum_body_bytes` (8 MiB), `maximum_redirects` (10),
`retry_on_stale_connection` (on), and `ca` (`HttpClient.Ca.System`, or `HttpClient.Ca.File(path)` for a PEM file).
`client!` fails when the CA certificates cannot be loaded, so call it in `init!`.

## Behaviour

- One client sends to any URL. The process's clients, on all its threads, share the connections: at most 64 for each
  thread in use at once per origin (scheme, host, port; a request that finds them all in use waits, then gets
  `HttpClientBusy`), idle ones close after 90 seconds, and at most 100 for each thread stay idle across origins.
  `HttpClient.configure!` in `init!` changes them
- A 4xx or 5xx response is `Ok`; look at `response.status()`
- Redirects (301, 302, 303, 307, 308) are followed. 301, 302, and 303 turn a request other than GET or HEAD into a GET
  without a body. Moving to another origin drops the secret headers and `Authorization`, `Cookie`,
  `Proxy-Authorization`, and `WWW-Authenticate`. A redirect from https to http is refused
- Headers are checked before anything is sent: names must be tokens, values must not contain CR, LF, or other control
  characters. `Host`, `Content-Length`, and `Transfer-Encoding` are the client's own
- Secret headers are written by the host, so the token never passes through Roc
- When an idle connection turns out closed by the server, the request is sent again on a new connection: any request
  of which nothing was sent, and GET, HEAD, OPTIONS, or TRACE when no response came back. Other methods return
  `HttpClientClosed`
- With `decompress` (on by default), a request without `Accept-Encoding` is sent with `Accept-Encoding: gzip, zstd`,
  and a gzip or Zstandard response comes back decompressed, without `Content-Encoding` and `Content-Length`, also when
  the app set `Accept-Encoding` itself (as reqwest does). `maximum_body_bytes` applies to the body decompressed too

## Errors

`HttpClientInvalidUrl(Str)`, `HttpClientInvalidMethod`, `HttpClientInvalidHeader(Str)` (the header's name),
`TcpResolveFailed`, `TcpResolveTimedOut`, `TcpConnectFailed`, `TcpConnectTimedOut`, `TcpTlsFailed`, `HttpClientBusy`,
`HttpClientTimedOut`, `HttpClientClosed`, `HttpClientInvalidResponse(Str)`, `HttpClientBodyTooLarge`,
`HttpClientOverloaded` (the process's requests hold more memory than `Server.Limits.request_memory`),
`HttpClientTooManyRedirects`, and `HttpClientInsecureRedirect`.

## Testing

`zig build test-http-client` runs `tests/http-client` against local HTTP and HTTPS servers (ECDSA and RSA
certificates from a CA made for the run) in every backend and allocator mode. `tests/roc/run-http-client-tests.sh`
runs the unit tests of the URL and HTTP/1.1 modules.

## Not supported yet

- Streaming bodies; Brotli responses
- Proxies, HTTP/2, cookies, and client certificates
