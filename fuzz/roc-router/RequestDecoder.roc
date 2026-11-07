import Reply
import RouteContext

# Fuzz-only stand-in for platform/RequestDecoder.roc, which decodes typed handler fields. The fuzz target only probes routes; it never reads a request.
RequestDecoder :: [].{
	State(provided) := { context : RouteContext(provided) }

	Request := [Default]

	from_context : RouteContext(provided) -> Try(a, Reply)
		where [a.parser_for : RequestDecoder.Request -> (RequestDecoder.State(provided) -> Try({ value : a, rest : RequestDecoder.State(provided) }, [Rejected(Reply), ..errs]))]
	from_context = |_context| Err(Reply.status(500))
}
