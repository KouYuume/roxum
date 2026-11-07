# Public API layout

The platform header in `platform/main.roc` declares the modules available to applications. Public routing and response APIs use dedicated modules such as `Router`, `Handler`, `RouteContext`, and `Reply`. Host-facing HTTP representation types live under `Http`.

An application supplies `program = { init!, routes }`. `init!` returns the application model and `Server.ListenOptions`; `Router.build` closes the router's route-tag and middleware-provided types. A handler returns `Try(Reply, Reply)`, allowing middleware to distinguish successful replies from failure replies.

Do not expose a host implementation type merely because glue needs it. In particular, socket pointers and internal body-reader tokens are not application APIs. Public modules should explain input contracts, errors, and lifetime restrictions rather than the implementation history.

Integrations declare their platform dependency explicitly. Compiler platform-identity checks and the compatibility manifest ensure they refer to the same platform as the application. See [integration releases](integration-releases.md).

`Extract` exposes both explicit extractor functions (such as `Extract.json`) and typed handler fields (such as `Extract.JsonBody`). Custom field types implement `parser_for`, optionally annotated with `Extract.Parser(value, provided)`, and use `Extract.reading` to access the request context. `RequestDecoder` implements record traversal and rejection capture internally and is not exported by the platform.
