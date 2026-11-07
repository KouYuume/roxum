import RequestHead
import Reply

## Work around a handler, at the stages of a request. A layer is a list
## of stages, added with `Router.layer` or `MethodRouter.layer`:
##
## ```roc
## Router.route("/items", MethodRouter.post(Handler.effectful(create_item!)))
##     .layer([Middleware.Stage.BeforeBody(require_api_key!)])
##     .layer([Middleware.Stage.AfterBody(verify_signature!)])
## ```
##
## A request runs the stages in this order, whatever order they are written
## in: `BeforeBody`, then `OnChunk` while the body arrives, then `AfterBody`,
## then the handler, then `AfterHandler`. Within one stage, the layer written
## first runs first. A reply made at some point (a stage that rejects, or the
## handler) goes out through the `AfterHandler` stages of the layers written
## before that point, so a layer that should see every reply is written first.
## The stages of one layer share its position: a reply the layer's own
## `BeforeBody` made does not go through its own `AfterHandler`.
##
## Stages run synchronously on one of the process's threads, so a layer
## cannot interrupt a handler that is still running.
Middleware :: [].{
	## One stage of work around a handler.
	##
	## - `BeforeBody`: runs before the body is received, with the request's
	##   metadata only. Returns the (possibly changed) metadata to go on, or a
	##   reply to answer at once; then the body is not received. A client that
	##   sent `Expect: 100-continue` has not sent the body yet.
	## - `OnChunk`: checks or transforms each part of the body as it arrives.
	## - `AfterBody`: runs with the whole body, before a handler that reads
	##   the body whole. Returns the (possibly changed) body, or a reply.
	##   A `Handler.streaming` handler skips it.
	## - `AfterHandler`: changes the reply on its way out.
	##
	## The callbacks of `BeforeBody`, `AfterBody`, and `AfterHandler` may
	## perform effects. A function annotated as pure (`->`) is passed in a
	## lambda: `Middleware.Stage.BeforeBody(|model, head| Ok(check(model, head)))`.
	Stage(model, tag, provided) := [
		BeforeBody((model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), Reply))),
		OnChunk(Middleware.ChunkCheck),
		AfterBody((model, RequestHead(tag, provided), List(U8) => Try(List(U8), Reply))),
		AfterHandler((model, RequestHead(tag, provided), Reply => Reply)),
	]

	## A check or transformation of a body's parts as they arrive, with state
	## kept for one request. The parts' boundaries are arbitrary.
	ChunkCheck := {
		step : List(U8) -> Try({ next : Middleware.ChunkCheck, bytes : List(U8) }, Reply),
		finish : {} -> Try({}, Reply),
	}.{
		## A check that starts each request from `initial`. `step` gets the state
		## and the next part, and returns the new state and the bytes to pass on
		## (the part itself, or a transformed part). `finish` runs after the last
		## part. Either returns a reply to stop the request.
		new : state, (state, List(U8) -> Try({ state : state, bytes : List(U8) }, Reply)), (state -> Try({}, Reply)) -> Middleware.ChunkCheck
		new = |initial, step, finish| Middleware.ChunkCheck.({
			step: |bytes| {
				done = step(initial, bytes)?
				Ok({ next: Middleware.ChunkCheck.new(done.state, step, finish), bytes: done.bytes })
			},
			finish: |{}| finish(initial),
		})

		## Passes `bytes` through the check, returning the check for the next part.
		step = |Middleware.ChunkCheck.(check), bytes| (check.step)(bytes)

		## Runs the check's end-of-body test.
		finish = |Middleware.ChunkCheck.(check)| (check.finish)({})
	}
}
