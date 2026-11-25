# Typed gRPC greeting service

This example registers typed `unary.Greeter/Greet`, `Watch`, `CountGreetings` and `Converse` methods from
`service.proto`. `Watch` produces three ordered greetings incrementally and
finishes with status OK. `CountGreetings` consumes names until EOF and returns
one count, including zero for an empty stream. `Converse` replies to names
while the request stream is open.
`Greet` returns a greeting, initial `service` metadata, and the request's `request-bin`
metadata as trailers. An empty name returns `INVALID_ARGUMENT`. The generated
route installs `grpc-timeout` before body reception. Message and body limits are
explicit in `app.roc`.

From the repository root, with the [pinned toolchain](../../../docs/toolchain.md):

```sh
bash integrations/roxum-grpc/example/checks.sh
zig build host
roc build --output=zig-out/grpc-example/server integrations/roxum-grpc/example/app.roc
zig-out/grpc-example/server
```

The server binds loopback on a free port and prints that port. In another terminal,
replace `PORT` with it:

```sh
zig-out/grpc-example/venv/bin/python integrations/roxum-grpc/example/client.py 127.0.0.1:PORT
```

The client checks a successful greeting, initial and binary trailing metadata,
the empty-name error, another successful call, the three streamed greetings, upload counts, and an exchange of names and replies
with final status on the same channel. No
reflection service or handwritten Protobuf bytes are required. Stop the server
with Ctrl-C.

`checks.sh` installs hash-pinned build/client dependencies and checks that committed
Roc bindings match the schema. Regeneration removes obsolete generator-owned
Roc modules; keep handwritten code outside `generated/`. After editing the schema,
regenerate them with:

```sh
zig-out/grpc-example/venv/bin/python integrations/roxum-grpc/example/generate.py
```

Use `python3 tools/check.py --only test-grpc-example` to run the two-thread server on
dev and speed with both allocators. The more exhaustive protocol, deadline and
cancellation matrices remain in `tests/grpc-unary` and `tests/grpc-streaming`.

For direct TLS on the 0.4 development branch, replace `Server.Protocol.Http2`
in `app.roc` with the following listener setting and rebuild:

```roc
Server.Protocol.Tls({ certificate_chain_path: "cert.pem", private_key_path: "key.pem" })
```

Start the server from the directory containing the certificate chain and key.
Pass the trusted CA to the client and use a target name covered by the server
certificate (here, `localhost`):

```sh
zig-out/grpc-example/venv/bin/python integrations/roxum-grpc/example/client.py localhost:PORT --ca ca.pem
```

See the [deployment guide](../../../docs/guides/deployment.md#inbound-tls-on-the-04-development-branch)
for credential rotation and limits, or the [reverse proxy guide](../../../docs/guides/reverse-proxy.md#native-grpc-over-tls)
for proxy termination. For released packages, follow the [distribution guide](../DISTRIBUTION.md).
