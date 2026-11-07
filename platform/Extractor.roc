import Reply
import RouteContext

## Reads a `value` from the route context, or fails with a `Reply` that should
## be sent instead. Use the ready-made extractors and combinators in `Extract`,
## and run one with `Extract.run!`. Because the error is already a `Reply`, a
## handler returning `Try(Reply, Reply)` can use `?` on the result.
Extractor(value, provided) := {
	run! : RouteContext(provided) => Try(value, Reply),
}
