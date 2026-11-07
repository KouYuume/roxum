# Layered service fixture

This application supports the layered-service and CRUD regression tests. It combines PostgreSQL, an outbound HTTP tax service, repositories, use cases, controllers, and event handlers.

Run `zig build test-layered-app` and `zig build test-crud-service` from the repository root. The test harness provides temporary configuration, credentials, a database, and a tax service.

For runnable public examples, see [hello](../../../examples/hello/README.md) and [DDD](../../../examples/ddd/README.md).
