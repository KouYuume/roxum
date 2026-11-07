import Handler
import Http
import Middleware
import Reply
import RequestHead

# Fuzz-only stand-in for platform/Pipeline.roc, which reads request bodies
# from the host and so needs the full Http.RequestBody. The fuzz target only
# probes routes; it never runs a handler or a stage.
Pipeline :: [].{
	before! : List(List(Middleware.Stage(model, tag, provided))), U64, model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), { at : U64, head : RequestHead(tag, provided), reply : Reply })
	before! = |_layers, _start, _model, head| Ok(head)

	after! : List(List(Middleware.Stage(model, tag, provided))), U64, model, RequestHead(tag, provided), Reply => Reply
	after! = |_layers, _at, _model, _head, reply| reply

	without_body! : List(List(Middleware.Stage(model, tag, provided))), model, RequestHead(tag, provided), (RequestHead(tag, provided) => Reply) => Reply
	without_body! = |_layers, _model, head, make!| make!(head)

	run! : List(List(Middleware.Stage(model, tag, provided))), U64, Handler(model, tag, provided), model, RequestHead(tag, provided), Http.Request, (Reply -> Reply) => Reply
	run! = |_layers, _start, _handler, _model, _head, _request, mark| mark(Reply.status(500))
}
