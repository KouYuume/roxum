import Handler
import HostBody
import Http
import HttpError
import Middleware
import Reply
import RequestHead
import RouteContext

## Runs a handler and the layers around it. `layers` lists them
## outermost first, as written; each layer is a list of `Middleware.Stage`s
## that share its position. A reply made at position `i`
## (a stage of layer `i` that rejects, or `List.len(layers)` for the handler
## and the body read) goes out through the `AfterHandler` layers of the layers
## before `i`, innermost first.
Pipeline :: [].{
	## Runs the `BeforeBody` layers from `start` on. `Err` holds the position
	## of the stage that answered, the metadata it saw, and its reply.
	before! : List(List(Middleware.Stage(model, tag, provided))), U64, model, RequestHead(tag, provided) => Try(RequestHead(tag, provided), { at : U64, head : RequestHead(tag, provided), reply : Reply })
	before! = |layers, start, model, head| {
		var $head = head
		var $index = start
		while $index < List.len(layers) {
			for stage in list_get(layers, $index) {
				match stage {
					Middleware.Stage.BeforeBody(check!) =>
						match check!(model, $head) {
							Ok(next) => { $head = next }
							Err(reply) => return Err({ at: $index, head: $head, reply })
						}
					Middleware.Stage.OnChunk(_) | Middleware.Stage.AfterBody(_) | Middleware.Stage.AfterHandler(_) => {}
				}
			}
			$index = $index + 1
		}
		Ok($head)
	}

	## Passes `reply`, made at position `at`, out through the `AfterHandler`
	## layers before `at`.
	after! : List(List(Middleware.Stage(model, tag, provided))), U64, model, RequestHead(tag, provided), Reply => Reply
	after! = |layers, at, model, head, reply| {
		var $reply = reply
		var $index = at
		while $index > 0 {
			$index = $index - 1
			layer = list_get(layers, $index)
			var $stage_index = List.len(layer)
			while $stage_index > 0 {
				$stage_index = $stage_index - 1
				match list_get(layer, $stage_index) {
					Middleware.Stage.AfterHandler(change!) => { $reply = change!(model, head, $reply) }
					Middleware.Stage.BeforeBody(_) | Middleware.Stage.OnChunk(_) | Middleware.Stage.AfterBody(_) => {}
				}
			}
		}
		$reply
	}

	## Runs the `BeforeBody` stages of `layers`, then `make!` with the metadata
	## they returned, without receiving the body (a fallback, a 405, or a bad path
	## parameter), and sends the reply out through the `AfterHandler` stages.
	without_body! : List(List(Middleware.Stage(model, tag, provided))), model, RequestHead(tag, provided), (RequestHead(tag, provided) => Reply) => Reply
	without_body! = |layers, model, head, make!|
		match Pipeline.before!(layers, 0, model, head) {
			Err(stopped) => Pipeline.after!(layers, stopped.at, model, stopped.head, stopped.reply)
			Ok(ready) => Pipeline.after!(layers, List.len(layers), model, ready, make!(ready))
		}

	## Runs the stages of `layers` after the `BeforeBody` ones before `start`
	## have run, then the handler. `request` already carries `head`'s metadata.
	## A reply made at `start` or later is passed to `mark` before it goes out,
	## so the router can name the route on it.
	run! : List(List(Middleware.Stage(model, tag, provided))), U64, Handler(model, tag, provided), model, RequestHead(tag, provided), Http.Request, (Reply -> Reply) => Reply
	run! = |layers, start, handler, model, head, request, mark|
		match Pipeline.before!(layers, start, model, head) {
			Err(stopped) => Pipeline.after!(layers, stopped.at, model, stopped.head, mark(stopped.reply))
			Ok(ready) => {
				# Without a `BeforeBody` stage, `ready` is `head`, whose metadata
				# `request` already carries; copying it back would change nothing.
				updated = if has_before_body(layers, start) { RequestHead.apply(ready, request) } else { request }
				made = match Handler.streaming_start(handler) {
					Ok(begin!) => stream!(layers, begin!, model, ready, updated)
					Err(NotStreaming) => whole!(layers, handler, model, ready, updated)
				}
				marked = if made.at >= start { mark(made.reply) } else { made.reply }
				Pipeline.after!(layers, made.at, model, ready, marked)
			}
		}
}

## Whether a layer at `start` or later has a `BeforeBody` stage.
has_before_body = |layers, start| {
	var $index = start
	while $index < List.len(layers) {
		for stage in list_get(layers, $index) {
			match stage {
				Middleware.Stage.BeforeBody(_) => return Bool.True
				Middleware.Stage.OnChunk(_) | Middleware.Stage.AfterBody(_) | Middleware.Stage.AfterHandler(_) => {}
			}
		}
		$index = $index + 1
	}
	Bool.False
}

## Receives the whole body, passes it through the `OnChunk` and `AfterBody`
## layers, and calls the handler with it.
whole! = |layers, handler, model, head, request| {
	end = List.len(layers)
	received = match request.body {
		Http.RequestBody.Stream(stream) => {
			match head.whole_body_limit {
				Bytes(bytes) => stream.limit_whole!(bytes)
				ServerDefault => {}
			}
			read_parts!(layers, |maximum| stream.read_whole!(maximum))
		}
		Http.RequestBody.Bytes(bytes) =>
			match within_limit(bytes, head.whole_body_limit) {
				Ok({}) => pass_parts(layers, bytes)
				Err(reply) => Err({ at: end, reply })
			}
		Http.RequestBody.Empty => pass_parts(layers, [])
	}
	match received {
		Err(stopped) => stopped
		Ok(body) =>
			match after_body!(layers, model, head, body) {
				Err(stopped) => stopped
				Ok(checked) => {
					context = RouteContext.{ request: { ..request, body: Http.RequestBody.Bytes(checked) }, path_params: head.path_params, provided: head.provided }
					reply = match Handler.run!(handler, model, context) {
						Ok(value) | Err(value) => value
					}
					{ at: end, reply }
				}
			}
	}
}

## Feeds the body to a streaming handler part by part, through the `OnChunk`
## layers.
stream! = |layers, begin!, model, head, request| {
	end = List.len(layers)
	match begin!(model, head) {
		Err(reply) => { at: end, reply }
		Ok(started) =>
			match request.body {
				Http.RequestBody.Stream(stream) => {
					match head.streamed_body_limit {
						Bytes(bytes) => stream.limit_streamed!(bytes)
						Unlimited => stream.limit_streamed!(18_446_744_073_709_551_615)
						ServerDefault => {}
					}
					feed_stream!(layers, checks_of(layers), started, stream)
				}
				Http.RequestBody.Bytes(bytes) =>
					match within_streamed_limit(bytes, head.streamed_body_limit) {
						Ok({}) => feed_bytes!(layers, checks_of(layers), started, bytes)
						Err(reply) => {
							started.abort!(Handler.StreamEnd.TooLarge)
							{ at: end, reply }
						}
					}
				Http.RequestBody.Empty => feed_bytes!(layers, checks_of(layers), started, [])
			}
	}
}

feed_stream! = |layers, checks, sink, stream|
	match stream.read!(part_bytes) {
		HostBody.RequestRead.Chunk(bytes) =>
			match pass_checks(checks, bytes) {
				Err(stopped) => {
					sink.abort!(Handler.StreamEnd.Rejected)
					stopped
				}
				Ok(passed) =>
					match sink.chunk!(passed.bytes) {
						Err(reply) => {
							sink.abort!(Handler.StreamEnd.Rejected)
							{ at: List.len(layers), reply }
						}
						Ok(next) => feed_stream!(layers, passed.checks, next, stream)
					}
			}
		HostBody.RequestRead.End => finish_stream!(layers, checks, sink)
		other => {
			failure = read_failure(other)
			sink.abort!(failure.end)
			{ at: List.len(layers), reply: failure.reply }
		}
	}

feed_bytes! = |layers, checks, sink, bytes|
	if List.is_empty(bytes) {
		finish_stream!(layers, checks, sink)
	} else {
		part = List.take_first(bytes, part_bytes)
		match pass_checks(checks, part) {
			Err(stopped) => {
				sink.abort!(Handler.StreamEnd.Rejected)
				stopped
			}
			Ok(passed) =>
				match sink.chunk!(passed.bytes) {
					Err(reply) => {
						sink.abort!(Handler.StreamEnd.Rejected)
						{ at: List.len(layers), reply }
					}
					Ok(next) => feed_bytes!(layers, passed.checks, next, List.drop_first(bytes, List.len(part)))
				}
		}
	}

finish_stream! = |layers, checks, sink|
	match finish_checks(checks) {
		Err(stopped) => {
			sink.abort!(Handler.StreamEnd.Rejected)
			stopped
		}
		Ok({}) => {
			reply = match sink.done!() {
				Ok(value) | Err(value) => value
			}
			{ at: List.len(layers), reply }
		}
	}

## Reads a whole body part by part through the `OnChunk` layers. With none,
## it asks for all of it at once, which the host answers in one part when the
## body has already arrived.
read_parts! = |layers, read!| {
	checks = checks_of(layers)
	maximum = if List.is_empty(checks) { whole_read_bytes } else { part_bytes }
	read_parts_help!(layers, checks, read!, maximum, [])
}

read_parts_help! = |layers, checks, read!, maximum, received|
	match read!(maximum) {
		HostBody.RequestRead.Chunk(bytes) =>
			match pass_checks(checks, bytes) {
				Err(stopped) => Err(stopped)
				Ok(passed) => read_parts_help!(layers, passed.checks, read!, maximum, List.concat(received, passed.bytes))
			}
		HostBody.RequestRead.End =>
			match finish_checks(checks) {
				Err(stopped) => Err(stopped)
				Ok({}) => Ok(received)
			}
		other => Err({ at: List.len(layers), reply: (read_failure(other)).reply })
	}

## Passes a body built in Roc code through the `OnChunk` layers, in parts the
## size the host reads.
pass_parts = |layers, bytes| {
	checks = checks_of(layers)
	# With no chunk checks, splitting and rebuilding an already received body
	# cannot change its bytes or reject it. Keep the original list instead.
	if List.is_empty(checks) { Ok(bytes) }
	else { pass_parts_help(checks, bytes, []) }
}

pass_parts_help = |checks, bytes, received|
	if List.is_empty(bytes) {
		match finish_checks(checks) {
			Err(stopped) => Err(stopped)
			Ok({}) => Ok(received)
		}
	} else {
		part = List.take_first(bytes, part_bytes)
		match pass_checks(checks, part) {
			Err(stopped) => Err(stopped)
			Ok(passed) => pass_parts_help(passed.checks, List.drop_first(bytes, List.len(part)), List.concat(received, passed.bytes))
		}
	}

## The `OnChunk` layers with their layers' positions, outermost first.
checks_of = |layers| {
	var $checks = []
	var $index = 0
	for layer in layers {
		for stage in layer {
			match stage {
				Middleware.Stage.OnChunk(check) => { $checks = List.append($checks, { at: $index, check }) }
				Middleware.Stage.BeforeBody(_) | Middleware.Stage.AfterBody(_) | Middleware.Stage.AfterHandler(_) => {}
			}
		}
		$index = $index + 1
	}
	$checks
}

## Passes one part through every check in order, each seeing the bytes the
## one before it passed on.
pass_checks = |checks, bytes| {
	var $bytes = bytes
	var $next = []
	for entry in checks {
		match Middleware.ChunkCheck.step(entry.check, $bytes) {
			Err(reply) => return Err({ at: entry.at, reply })
			Ok(stepped) => {
				$bytes = stepped.bytes
				$next = List.append($next, { at: entry.at, check: stepped.next })
			}
		}
	}
	Ok({ checks: $next, bytes: $bytes })
}

finish_checks = |checks| {
	for entry in checks {
		match Middleware.ChunkCheck.finish(entry.check) {
			Err(reply) => return Err({ at: entry.at, reply })
			Ok({}) => {}
		}
	}
	Ok({})
}

## Runs the `AfterBody` layers in order.
after_body! = |layers, model, head, body| {
	var $body = body
	var $index = 0
	for layer in layers {
		for stage in layer {
			match stage {
				Middleware.Stage.AfterBody(check!) =>
					match check!(model, head, $body) {
						Ok(next) => { $body = next }
						Err(reply) => return Err({ at: $index, reply })
					}
				Middleware.Stage.BeforeBody(_) | Middleware.Stage.OnChunk(_) | Middleware.Stage.AfterHandler(_) => {}
			}
		}
		$index = $index + 1
	}
	Ok($body)
}

within_limit = |bytes, limit|
	match limit {
		Bytes(maximum) if List.len(bytes) > maximum => Err(too_large)
		Bytes(_) | ServerDefault => Ok({})
	}

within_streamed_limit = |bytes, limit|
	match limit {
		Bytes(maximum) if List.len(bytes) > maximum => Err(too_large)
		Bytes(_) | Unlimited | ServerDefault => Ok({})
	}

read_failure = |read|
	match read {
		HostBody.RequestRead.TooLarge => { end: Handler.StreamEnd.TooLarge, reply: too_large }
		HostBody.RequestRead.TimedOut => { end: Handler.StreamEnd.TimedOut, reply: Reply.error(HttpError.make(408, "request body timed out")) }
		HostBody.RequestRead.Closed => { end: Handler.StreamEnd.BadRequest, reply: Reply.error(HttpError.bad_request("request body stream is closed")) }
		HostBody.RequestRead.BadRequest => { end: Handler.StreamEnd.BadRequest, reply: Reply.error(HttpError.bad_request("invalid request body")) }
		HostBody.RequestRead.Failed => { end: Handler.StreamEnd.Failed, reply: Reply.error(HttpError.internal("request body read failed")) }
		HostBody.RequestRead.InvalidLimit => { end: Handler.StreamEnd.Failed, reply: Reply.error(HttpError.internal("request body read limit is invalid")) }
		HostBody.RequestRead.Chunk(_) | HostBody.RequestRead.End => { end: Handler.StreamEnd.Failed, reply: Reply.error(HttpError.internal("request body read failed")) }
	}

too_large = Reply.error(HttpError.make(413, "request body too large"))

## The most the host returns in one read.
part_bytes = 16 * 1024
## A read of a whole body that asks for all of it.
whole_read_bytes = 18_446_744_073_709_551_615

list_get = |items, index|
	match List.get(items, index) {
		Ok(item) => item
		Err(_) => crash "Pipeline: index out of range"
	}

# Empty input and the nearest byte lengths around the chunk boundary must
# preserve the whole body when there are no chunk checks.
expect {
	layers : List(List(Middleware.Stage({}, [], {})))
	layers = []
	var $ok = Bool.True
	for length in [0, part_bytes - 1, part_bytes, part_bytes + 1] {
		bytes = List.repeat(42.U8, length)
		$ok = $ok and match pass_parts(layers, bytes) {
			Ok(result) => result == bytes
			Err(_) => Bool.False
		}
	}
	$ok
}

# A present check must still transform every chunk and finish with its state.
expect {
	check = Middleware.ChunkCheck.new(
		0.U64,
		|count, bytes| Ok({ state: count + List.len(bytes).to_u64(), bytes: List.map(bytes, |_byte| 7.U8) }),
		|count| if count == (part_bytes + 1).to_u64() { Ok({}) } else { Err(too_large) },
	)
	layers : List(List(Middleware.Stage({}, [], {})))
	layers = [[Middleware.Stage.OnChunk(check)]]
	match pass_parts(layers, List.repeat(42.U8, part_bytes + 1)) {
		Ok(bytes) => bytes == List.repeat(7.U8, part_bytes + 1)
		Err(_) => Bool.False
	}
}

# Even an empty body must call finish when a check exists.
expect {
	check = Middleware.ChunkCheck.new({}, |state, bytes| Ok({ state, bytes }), |_state| Err(too_large))
	layers : List(List(Middleware.Stage({}, [], {})))
	layers = [[Middleware.Stage.OnChunk(check)]]
	match pass_parts(layers, []) {
		Err(stopped) => stopped.at == 0
		Ok(_) => Bool.False
	}
}
