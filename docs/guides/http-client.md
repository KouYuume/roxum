# Calling HTTP APIs

roxum calls outside HTTP and HTTPS APIs through the
[`roxum-http-client`](../../integrations/roxum-http-client/README.md) package. The protocol is Roc; the host keeps the
connections and waits for the server. While one request waits for an answer, its thread serves other requests.

The code on this page follows the [layered-service test fixture](../../tests/layered-app/fixture/README.md), whose
`api/TaxRateApi.roc` asks a tax-rate service for the rate on every quote; `zig build test-layered-app` runs it against
a stand-in service, and `zig build test-http-client` checks the client itself.

## Adding the package

Requests and responses are [roc-lang/http](https://github.com/roc-lang/http)'s `Request` and `Response`. Name that
package by the same URL as `roxum-http-client` does, so both use the same types:

```roc
app [program] {
	pf: platform "../../platform/main.roc",
	hc: "../../integrations/roxum-http-client/package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import hc.HttpClient
import http.Method
import http.Request
```

## A client in `init!`

Make one client in `init!` and keep it in the model. One client sends to any URL, and all the process's clients share
the connections.

```roc
client = HttpClient.client!(HttpClient.Config.{}).map_err(|_| StartupErr("cannot load the CA certificates"))?
```

`HttpClient.Config` takes:

| field | default | |
|---|---|---|
| `timeout_milliseconds` | 30 s | the whole exchange, redirects included; a request's `with_timeout` takes precedence |
| `maximum_body_bytes` | 8 MiB | a larger response is `HttpClientBodyTooLarge`, as it came and decompressed |
| `maximum_redirects` | 10 | |
| `retry_on_stale_connection` | on | see [Connections](#connections) |
| `ca` | `HttpClient.Ca.System` | `HttpClient.Ca.File(path)` trusts the CA certificates in a PEM file instead, such as a company CA |
| `decompress` | on | see [Compressed responses](#compressed-responses) |

`client!` loads the CA certificates and fails when there are none, so a container image without them stops at
startup rather than at the first call. On Debian and Alpine images, install `ca-certificates`.

## Sending a request

```roc
request = Request.from_method(Method.GET)
	.with_uri("https://tax.example.com/rates/JP")
	.add_header("Accept", "application/json")
	.with_timeout(TimeoutMilliseconds(2_000))

response = HttpClient.send!(model.client, request)?
if response.status() == 200 {
	rate : Try({ rate_percent : U64 }, _)
	rate = Encoding.Json.parse(Str.from_utf8_lossy(response.body()))
	...
}
```

- A 4xx or 5xx response is `Ok`. Look at `response.status()`: a 404 from the API may mean "no such item" rather than
  a failure
- Header names must be tokens and values must not contain CR, LF, or other control characters; the client checks
  before sending anything. It sets `Host` and `Content-Length` itself, so the request must not
- Compressed responses come back decompressed; see [Compressed responses](#compressed-responses)

## Compressed responses

With `decompress` on (the default), a request without `Accept-Encoding` is sent with `Accept-Encoding: gzip, zstd`,
and a response with `Content-Encoding: gzip` or `zstd` comes back decompressed, without `Content-Encoding` and
`Content-Length`. That holds when you set `Accept-Encoding` yourself too, as reqwest does; another coding you ask for,
such as `br`, comes back as it came, with its `Content-Encoding`. `maximum_body_bytes` applies to the body
decompressed as well, so a small body that would expand to gigabytes is `HttpClientBodyTooLarge` once it passes the
limit, and one that does not decompress is `HttpClientInvalidResponse`. The host decompresses off the request
threads. With `decompress: Bool.False`, nothing is added or decompressed.

## Tokens and API keys

An API key or token travels as a secret header: the host writes it into the request, and Roc code holds only a
handle. Read it in `init!` from a file of its own, like a database password:

```roc
tax_token = Secret.from_file!(settings.tax.token_file).map_err(|_| StartupErr("cannot read the tax token file"))?
```

and give it to the request that needs it:

```roc
HttpClient.send_with!(model.client, request, HttpClient.SendOptions.{
	secret_headers: [{ name: "Authorization", prefix: "Bearer ", secret: model.tax_token }],
})
```

The secret goes only with that request. Put the call in an adapter (`TaxRateApi` in the example), so the rest of the
app neither sees the token nor repeats the options. For `Authorization: Basic`, store the already encoded
`user:password` in the file.

## Redirects

301, 302, 303, 307, and 308 are followed, up to `maximum_redirects`:

- 301, 302, and 303 turn a request other than GET or HEAD into a GET without a body; 307 and 308 repeat it
- Moving to another origin (scheme, host, or port) drops the secret headers and `Authorization`, `Cookie`,
  `Proxy-Authorization`, and `WWW-Authenticate`
- A redirect from https to http is `HttpClientInsecureRedirect`: the request would travel in plain text

## Connections

- At most 64 connections for each thread to one origin are in use at once. A request that finds them all in use
  waits for one, and gets `HttpClientBusy` if none comes back before its deadline
- Idle connections are reused, close after 90 seconds, and at most 100 for each thread stay idle across all origins
- These limits belong to the process, not to a client, and its threads share the connections. Change them in `init!`,
  before the first request; `Fixed` sets the process's own number:

  ```roc
  HttpClient.configure!(HttpClient.Limits.{ maximum_requests_per_host: Server.Count.Fixed(512), maximum_idle_connections: Server.Count.Fixed(800) })?
  ```

  `idle_timeout_milliseconds` (90 s) is the third. Called after a request was sent, it fails

When the server closes an idle connection just as it is reused, the request may fail without an answer. The client
then sends it again on a new connection, but only when that cannot repeat it on the server: any request of which
nothing was sent, and GET, HEAD, OPTIONS, or TRACE when no response came back. A POST, PUT, PATCH, or DELETE gets
`HttpClientClosed` instead. Set `retry_on_stale_connection: Bool.False` for an API whose GETs change something.

## Errors

| error | meaning | typical handling |
|---|---|---|
| `HttpClientTimedOut` | the deadline passed | 503 or 504 |
| `HttpClientBusy` | every connection to that origin stayed in use until the deadline | 503 |
| `HttpClientClosed` | the server closed the connection before the response ended | 502 |
| `HttpClientInvalidResponse(Str)` | the answer was not HTTP/1.x | 502 |
| `HttpClientBodyTooLarge` | the body is over `maximum_body_bytes` | 502 |
| `HttpClientOverloaded` | the process's requests hold more memory than `Server.Limits.request_memory`, so the response was not read | 503 |
| `HttpClientTooManyRedirects`, `HttpClientInsecureRedirect` | as named | 502 |
| `TcpResolveFailed`, `TcpResolveTimedOut` | the host name did not resolve | 502 |
| `TcpConnectFailed`, `TcpConnectTimedOut` | no address accepted a connection | 502 |
| `TcpTlsFailed` | the certificate is not trusted, or does not name the host | 502 |
| `HttpClientInvalidUrl(Str)`, `HttpClientInvalidMethod`, `HttpClientInvalidHeader(Str)` | the request itself is wrong | a bug in the app |

In an adapter, map these to what the core understands (`Unavailable` in the example) and log which call failed.
Messages carry the header's name, never its value.

## A call that fails half-way

A handler that calls an API and also changes the database can fail between the two: the payment API charged the
card, then the database write failed; or the order was committed, then the confirmation call timed out and the client
retries. A database transaction cannot undo the outside call. Choose what fits the operation:

- **Idempotency keys**: send a key per operation (`Idempotency-Key` for APIs that support it, such as payment
  APIs), so a repeated call counts once
- **Outbox**: write "call this API" into the same transaction as the change, and let a separate job make the call after
  the commit
- **Compensation**: undo the outside effect when a later step fails, such as refunding a charge

Do not call outside APIs inside `Postgres.transaction!`: the transaction keeps its connection and locks while it
waits ([Databases](database.md#transactions)).

## Not supported yet

- Reading a body as a stream
- Brotli responses, proxies, HTTP/2, cookies, and client certificates


Response framing is bounded separately from the decoded body. A response head
and each chunk-size or trailer line may occupy at most 64 KiB. The retained wire
buffer is limited to eight times `maximum_body_bytes` plus 64 KiB, including
chunk framing and trailers. The wire budget is checked first; exceeding it returns
`HttpClientBodyTooLarge`. Within that budget, oversized heads or chunk lines return
`HttpClientInvalidResponse`. These limits also apply to fragmented input.
