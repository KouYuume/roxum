# Architecture

An application supplies `program = { init!, routes }`. Initialization creates the application model and listener configuration. `Router.build` closes the typed router for the platform. Handlers and middleware produce `Reply` values; the platform translates them into HTTP responses.

```text
Application: model, routes, handlers, middleware
                    |
Roc platform: routing, extraction, response policy
                    |
Generated ABI: typed values and ownership transfer
                    |
Zig host: supervisor, workers, fibers, event loops, effects
                    |
             sockets and operating system
```

The Roc layer owns application policy and pure transformations. The host owns resources that require operating-system access. Integrations compose the capabilities exposed by the platform instead of introducing their own hosted ABI.

The supervisor manages worker processes. Each worker runs Roc threads sharing a poller and connection table, with request fibers. A request waiting for external I/O yields its fiber so that its thread can serve other requests. The model and router outlive individual requests; request allocations and effect handles must not escape their request lifetime.

The generated glue is the source of truth for the host ABI. Host archives and Roc platform sources must be built together. See [execution and ownership](execution-model.md) for lifetime rules and [I/O scheduling](io-execution.md) for suspension and cancellation.

Public behavior is documented in the [guides](../README.md). Contract tests cover ownership and allocation; E2E tests exercise the Roc/host boundary across compiler backends and allocator modes.
