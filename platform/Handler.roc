import Status
import Http
import ResponseWriter
import RequestDecoder
import Reply
import RequestHead
import RouteContext

## The code that answers a request. A handler made with `pure`, `stateful`,
## `effectful`, or `static` runs after the platform has received the whole
## body: its `RouteContext` holds the body as `Bytes`, and the
## extractors read that same body however many times they are run. A handler
## made with `streaming` gets the body in parts as it arrives on both HTTP/1
## and HTTP/2, without holding the complete body.
Handler(model, tag, provided) := [
	Pure((RouteContext(provided) -> Try(Reply, Reply))),
	Stateful((model, RouteContext(provided) -> Try(Reply, Reply))),
	Effectful((model, RouteContext(provided) => Try(Reply, Reply))),
	RequestIndependent(({} -> Reply)),
	Duplex((model, RequestHead(tag, provided) => Try({ status : Status, headers : List(Http.ResponseHeader), interest : Handler.Interest, sink : Handler.DuplexSink }, Reply))),
	Streaming((model, RequestHead(tag, provided) => Try(Handler.Sink, Reply))),
].{
	pure = |handler| Pure(handler)
	stateful = |handler| Stateful(handler)
	effectful = |handler| Effectful(handler)

	## A response that does not depend on the request. Values computed at the top
	## level of a module are evaluated when the app is built, so an expensive
	## page defined as a constant costs nothing per request:
	##
	## ```roc
	## page = render_docs(sections)
	## Router.route("/docs", MethodRouter.get(Handler.static(|{}| Reply.text(page))))
	## ```
	static = |handler| Handler.(RequestIndependent(handler))

	## A handler whose one argument, a record, says what to read from the request
	## by its field types; see `Extract`.
	typed : (model, input => Try(Reply, Reply)) -> Handler(model, tag, provided)
		where [input.parser_for : RequestDecoder.Request -> (RequestDecoder.State(provided) -> Try({ value : input, rest : RequestDecoder.State(provided) }, [Rejected(Reply), ..errs]))]
	typed = |handler!| Handler.(
		Effectful(
			|model, context| {
				value = RequestDecoder.from_context(context)?
				handler!(model, value)
			},
		),
	)

	## A handler that gets the body in parts as it arrives, holding only one
	## part at a time, for uploads larger than a body held whole:
	##
	## - `begin!` runs before the body is received, with the request's metadata,
	##   and returns the state to start from, or a reply to answer at once.
	## - `chunk!` gets the state and the next part of the body, and returns the
	##   next state. The parts' boundaries are arbitrary; `OnChunk` stages have
	##   already passed them.
	## - `done!` runs after the whole body arrived and returns the reply.
	## - `abort!` runs when the request ends before `done!`: the client
	##   disconnected or sent an invalid body (`BadRequest`), the body passed
	##   its limit (`TooLarge`), the body timeout passed (`TimedOut`), a host
	##   failure (`Failed`), or a stage or `chunk!` rejected it (`Rejected`).
	##   The platform answers with the matching status (400, 413, 408, 500, or
	##   the rejecting reply). Use it to clean up what `chunk!` started, such
	##   as a temporary file. It does not run if the handler crashes. HTTP/2
	##   transport reset, timeout and disconnect abandon the request instead
	##   of running `abort!`; route-limit and callback rejection still run it.
	##
	## The streamed body limit applies (`Server.Limits` or `BodyLimit.streamed`).
	## `AfterBody` stages do not run.
	streaming : Handler.Streaming(model, state, tag, provided) -> Handler(model, tag, provided)
	streaming = |callbacks| Handler.(
		Streaming(
			|model, head| {
				state = (callbacks.begin!)(model, head)?
				Ok(sink(model, state, callbacks))
			},
		),
	)

	## Independent HTTP/2 input and output. begin! runs before headers and may
	## reject with a reply. ready! receives checked input and/or writable readiness
	## after response middleware and headers. Return Await with the next state and
	## interests, or Finish with trailers. Use ResponseWriter.try_write! to avoid
	## blocking input behind output. Interests must exclude input after End or Failed.
	## OnChunk checks run in order, including their EOF checks; a rejection after
	## headers resets the stream. AfterBody does not run. HTTP/1 returns 501 without
	## invoking either callback. Reset and timeout abandon the request.
	duplex : Handler.DuplexCallbacks(model, state, tag, provided) -> Handler(model, tag, provided)
	duplex = |callbacks| Handler.(Duplex(|model, head| {
		started = (callbacks.begin!)(model, head)?
		Ok({ status: started.status, headers: started.headers, interest: started.interest, sink: duplex_sink(started.state, callbacks.ready!) })
	}))

	Interest := [Read, Write, Both]

	DuplexEvent := { input : [Idle, Chunk(List(U8)), End, Failed(Handler.StreamEnd)], writable : Bool }

	DuplexNext(state) := [
		Await({ state : state, interest : Handler.Interest }),
		Finish(List(Http.ResponseHeader)),
	]

	DuplexCallbacks(model, state, tag, provided) := {
		begin! : model, RequestHead(tag, provided) => Try({
			state : state, status : Status, headers : List(Http.ResponseHeader), interest : Handler.Interest,
		}, Reply),
		ready! : state, Handler.DuplexEvent, ResponseWriter => Try(Handler.DuplexNext(state), [StreamClosed]),
	}

	## Platform-owned callback state; applications use duplex.
	DuplexSink := {
		ready! : Handler.DuplexEvent, ResponseWriter => Try([Await({ sink : Handler.DuplexSink, interest : Handler.Interest }), Finish(List(Http.ResponseHeader))], [StreamClosed]),
	}.{
		ready! = |Handler.DuplexSink.(callbacks), event, writer| (callbacks.ready!)(event, writer)
	}

	duplex_start = |handler|
		match handler {
			Duplex(begin!) => Ok(begin!)
			Pure(_) | Stateful(_) | Effectful(_) | RequestIndependent(_) | Streaming(_) => Err(NotDuplex)
		}

	## The callbacks of a streaming handler; see `streaming`. `abort!` may be
	## left out when there is nothing to clean up.
	Streaming(model, state, tag, provided) := {
		begin! : model, RequestHead(tag, provided) => Try(state, Reply),
		chunk! : state, List(U8) => Try(state, Reply),
		done! : model, state => Try(Reply, Reply),
		abort! : state, Handler.StreamEnd => {} ?? |_state, _reason| {},
	}

	## Why a streaming request ended before `done!` ran.
	StreamEnd := [BadRequest, TooLarge, TimedOut, Failed, Rejected]

	## A streaming handler in progress, with its state inside.
	Sink := {
		chunk! : List(U8) => Try(Handler.Sink, Reply),
		done! : {} => Try(Reply, Reply),
		abort! : Handler.StreamEnd => {},
	}.{
		chunk! = |Handler.Sink.(callbacks), bytes| (callbacks.chunk!)(bytes)
		done! = |Handler.Sink.(callbacks)| (callbacks.done!)({})
		abort! = |Handler.Sink.(callbacks), reason| (callbacks.abort!)(reason)
	}

	## The `begin!` of a streaming handler, for the router.
	streaming_start = |handler|
		match handler {
			Streaming(begin!) => Ok(begin!)
			Pure(_) | Stateful(_) | Effectful(_) | RequestIndependent(_) | Duplex(_) => Err(NotStreaming)
		}

	## Runs a handler that takes its body whole. A streaming handler answers
	## 500: run it through a router instead.
	run! = |handler, model, context|
		match handler {
			Pure(call) => call(context)
			Stateful(call) => call(model, context)
			Effectful(call!) => call!(model, context)
			RequestIndependent(call) => Ok(call({}))
			Streaming(_) | Duplex(_) => Err(Reply.status(500))
		}
}

sink = |model, state, callbacks| Handler.Sink.(
	{
		chunk!: |bytes| {
			next = (callbacks.chunk!)(state, bytes)?
			Ok(sink(model, next, callbacks))
		},
		done!: |{}| (callbacks.done!)(model, state),
		abort!: |reason| (callbacks.abort!)(state, reason),
	},
)

duplex_sink = |state, ready!| Handler.DuplexSink.({
	ready!: |event, writer|
		match ready!(state, event, writer)? {
			Handler.DuplexNext.Await(next) => Ok(Await({ sink: duplex_sink(next.state, ready!), interest: next.interest }))
			Handler.DuplexNext.Finish(trailers) => Ok(Finish(trailers))
		},
})
