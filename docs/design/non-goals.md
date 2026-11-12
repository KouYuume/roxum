# Scope and non-goals

roxum focuses on independently deployable HTTP APIs and backend services that fit Roc's language and effect model. Some features are outside the planned scope; others belong in libraries or integrations rather than the core.

## Focus

roxum provides typed HTTP handling, composable routing and middleware, explicit effects, and execution and resource management. Applications keep their business logic in pure Roc functions. HTTP correctness, ownership, cancellation, compiler and ABI compatibility, and evidence-based performance work remain core responsibilities.

To keep its focus on backend services, roxum does not aim to provide:

| Area | Outside roxum's scope |
|---|---|
| Browser UI runtime | DOM management, UI components, browser state, frontend routing, and UI event or subscription models. |
| Integrated frontend/backend programming | Transparent server functions and framework-specific UI synchronization protocols. |
| Template toolchain | A core-owned template language, compiler, rendering runtime, and editor tooling. Independent HTML template tools can be used as described below. |
| Integrated UI development server | Template hot replacement and automatic browser updates as a unified framework workflow. |
| Integrated database workflow | A platform-owned system combining SQL type generation, schema synchronization, and automatic migrations. |

Serving HTML, static assets, or an API used by a browser remains in scope. Applications can use rendering libraries and database integrations without roxum owning the surrounding UI or database toolchain. Existing static-page support is not excluded by this boundary.

IPv4/IPv6 and Unix listeners are core networking capabilities. Finite HTTP/2 listeners and response trailers are implemented; RPC deadlines remain a planned foundation for gRPC server support; see the [implementation plan](../plans/grpc.md). Inbound TLS remains a separate candidate. WebSocket is deferred until a concrete use case that existing HTTP requests plus SSE cannot satisfy, or a WebSocket interoperability requirement, justifies its implementation and maintenance cost. This does not assume that another Roc platform supplies a replacement backend.

## Choosing a Roc platform for your application

For applications centered on browser UI or hypermedia pages, consider these Roc projects:

- **Browser interfaces written in Roc:** explore [Joy](https://github.com/niclas-ahden/joy), with its model, update, and render approach to browser applications. Its examples are a useful starting point for building interactive UI in Roc.
- **HTML templates and SQLite in one application workflow:** explore [roux](https://github.com/Eldhus/roux), which combines typed HTML templates, typed SQLite queries, schema migrations, and a development command for rebuilding applications as you edit them.

Follow each project's documentation for setup, supported environments, and examples. These are suggestions for choosing an application development model. A browser application can also communicate with a separately deployed roxum API over HTTP.

## Features excluded unless strong demand emerges

The following features are explicitly outside the planned scope unless strong user demand justifies reconsideration. They are not a backlog of promised features.

| Feature | Reason for excluding it | Demand that could justify reconsideration |
|---|---|---|
| CONNECT | Establishing tunnels serves proxy use cases and requires connection management beyond ordinary request handling. | A concrete need to build a tunneling proxy with roxum. |
| TRACE | Request loopback diagnostics are not needed for ordinary application behavior. | An operational requirement that specifically depends on TRACE. |
| Arbitrary extension HTTP methods | Accepting and routing methods beyond roxum's supported set expands the API for specialized protocols rather than ordinary web applications. Examples include WebDAV's PROPFIND, MKCOL, COPY, MOVE, LOCK, and UNLOCK. | A concrete interoperability requirement, such as serving existing WebDAV clients. |

Extension methods here mean methods outside roxum's supported set, including methods standardized by other specifications. Supporting their routing would not by itself implement the associated protocols.

Reconsideration should identify the application or client that needs the feature, why existing capabilities do not meet that need, and the implementation and maintenance costs. Strong demand opens a design discussion; it does not automatically commit roxum to implementation. Any accepted capability must follow the [platform boundary](platform-boundary.md).

Unsupported requests still require correct error handling. Excluding a feature does not exclude fixes to request parsing, rejection, or resource cleanup.

Other limitations listed in the [README](../../README.md#limitations) are not automatically non-goals. Add them here only after an explicit scope decision.

## Features owned by libraries and integrations

### gRPC and Protobuf

gRPC-specific message envelopes, metadata conventions, timeout parsing, service dispatch, and status mapping belong in an integration. Protobuf encoding and decoding belong in a reusable pure library; schema compilation and Roc code generation belong in build-time tools.

The core supplies generic HTTP/2 transport, response trailers, and request-scoped I/O, deadline, and cancellation capabilities. The host enforces connection and stream lifetimes without interpreting Protobuf schemas or gRPC statuses. Full-duplex I/O must be designed explicitly before streaming RPC APIs are published; existing HTTP streaming support is not a promise of that capability.

The [gRPC plan](../plans/grpc.md) starts with server-side Unary RPC and then expands to streaming. These are planned capabilities, not current support. Outbound gRPC and inbound TLS are separate work.

### HTML templates and AOT generation

Applications should be able to author HTML as HTML templates and use the rendered output in responses or SSE events. Template parsing, ahead-of-time (AOT) generation, and HTML escaping belong in independent tools and libraries, not in the roxum core.

The preferred integration approach is to generate ordinary Roc rendering functions before compiling the application:

```text
Build: HTML templates -> generator -> Roc types and rendering functions -> Roc compiler
Runtime: rendering function + application data -> Str -> HTML response or SSE event
```

The generator checks template structure and emits code that Roc can type-check against application data. A rendering library handles escaping appropriate to the output context. Dynamic data is still formatted and inserted at runtime; AOT does not precompute values that depend on a request or a later event. This differs from [build-time pages](../guides/static-pages.md), where the complete content can be a constant.

The rendering layer need not depend on roxum: a pure function returning `Str` can be reused by other platforms. An optional roxum integration can adapt that output to an HTML response or a frontend-specific SSE event format. Existing response APIs and `roxum-sse` provide the transport; SSE framing does not replace HTML escaping. Browser-side code determines how an event updates the DOM.

The application build or the independent generator's wrapper runs template generation before the Roc build. This approach requires no dedicated host effect or host rendering runtime. Runtime bytecode rendering and template hot replacement are separate designs, not prerequisites for authoring HTML templates or sending HTML fragments over SSE.

This is an integration direction, not an existing bundled template generator. Start with existing public APIs and consider a general-purpose core addition only if a concrete implementation demonstrates a missing capability.

### Sessions, CSRF, OAuth, and JWT

Session management, CSRF protection, OAuth flows, and JWT processing belong in libraries or integrations, not in the roxum core. Application-specific authentication and authorization policy remains in the application.

Integrations should compose existing capabilities first: cookies, cryptographically secure randomness, wall-clock time, HTTPS requests, database access, and host-held secrets. The cookie integration already supports HMAC-signed cookies; signing does not encrypt their contents.

If an integration cannot meet its requirements with existing capabilities, consider the smallest general-purpose addition at the appropriate boundary. Examples to evaluate when needed include authenticated encryption for encrypted cookies and cryptographic signing or verification for JWT algorithms not covered by the existing API. These are capability candidates, not commitments to implement them. Pure protocol handling and validation remain in Roc; operations requiring host-held keys must preserve the secret ownership contract.

Session storage and its consistency across workers or instances must be explicit. Integrations can use an external store through existing I/O capabilities; session support does not by itself justify adding a session-specific store to the host.

### OpenAPI

OpenAPI generation, validation, and documentation UI belong in libraries or integrations, not in the roxum core. roxum does not provide OpenAPI-specific host effects.

An integration can keep explicit API metadata and produce both roxum routes and an OpenAPI document from a shared definition. Document construction and serialization are pure transformations; serving the document or UI uses existing HTTP response capabilities.

Automatic derivation requires enough metadata to describe inputs, responses, authentication, and middleware errors. A handler returning `Try(Reply, Reply)` does not by itself describe every possible response schema or status. This is a metadata and Roc API design concern, not a reason to add host functionality.

General-purpose Roc APIs needed by integrations may be considered when a concrete requirement demonstrates the need. They must follow the [platform boundary](platform-boundary.md) and [public API layout](public-api-layout.md), without exposing host internals or coupling the core to OpenAPI.
