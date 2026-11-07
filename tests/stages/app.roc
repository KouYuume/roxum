app [program] { pf: platform "../../platform/main.roc" }

import pf.BodyLimit
import pf.Extract
import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.Log
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.ResponseHeader
import pf.RouteContext
import pf.Router
import pf.Server

## M24 phase 2: the stages of a request and the positions of layers.
Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}|
	Ok({
		model: {},
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes =
	Router.new
		# Written in the order AfterBody, BeforeBody, BeforeBody: the stages run
		# by kind, and the BeforeBody layers in the order written.
		.route(
			"/order",
			MethodRouter.post(Handler.effectful(echo!))
				.layer([Middleware.Stage.AfterBody(|_model, _head, body| Ok(List.concat(body, "!".to_utf8())))])
				.layer(marker("a"))
				.layer(marker("c")),
		)
		# A reply made at a layer's position goes out through the layers
		# written before it, and not through its own AfterHandler.
		.route(
			"/reject",
			MethodRouter.post(Handler.effectful(echo!))
				.layer([tag("a")])
				.layer([require_key, tag("r")])
				.layer([tag("c")]),
		)
		.route(
			"/signed",
			MethodRouter.post(Handler.effectful(twice!))
				.layer([tag("outer")])
				.layer([Middleware.Stage.AfterBody(verify_body)]),
		)
		.route(
			"/chunks",
			MethodRouter.post(Handler.effectful(echo!))
				.layer([Middleware.Stage.OnChunk(at_most(5))])
				.layer([Middleware.Stage.OnChunk(upper)]),
		)
		.route(
			"/stream",
			MethodRouter.post(count)
				.layer([Middleware.Stage.OnChunk(upper)])
				.layer(BodyLimit.streamed(Server.BodyLimit.Bytes(8))),
		)
		.route("/stream-any", MethodRouter.post(count))
		.route(
			"/stream-reject",
			MethodRouter.post(count)
				.layer([Middleware.Stage.OnChunk(at_most(3))]),
		)
		# Without require_json the Content-Type is checked after the body; with
		# it, before.
		.route("/json-late", MethodRouter.post(Handler.effectful(json_name!)))
		.route(
			"/json-early",
			MethodRouter.post(Handler.effectful(json_name!))
				.layer(Extract.require_json({})),
		)
		.route(
			"/whole-limit",
			MethodRouter.post(Handler.effectful(echo!))
				.layer(BodyLimit.whole(4)),
		)

## Prefixes the path before the body and tags the reply on its way out.
marker = |name| [
	Middleware.Stage.BeforeBody(|_model, head| Ok({ ..head, path: "${name}:${head.path}" })),
	tag(name),
]

tag = |name| {
	text : Str
	text = name
	value = match HeaderValue.from_str(text) {
		Ok(header_value) => header_value
		Err(_) => crash "stage test marker contains a line break"
	}
	Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("x-stage"), value }]))
}

require_key = Middleware.Stage.BeforeBody(
	|_model, head|
		if List.any(head.headers, |field| field.name == HeaderName.("x-key")) {
			Ok(head)
		} else {
			Err(Reply.status(401))
		},
)

verify_body = |_model, _head, body|
	if body == "ok".to_utf8() {
		Ok(body)
	} else {
		Err(Reply.text("bad body").with_status(400))
	}

## Fails with 413 once more than `maximum` bytes have passed.
at_most = |maximum| Middleware.ChunkCheck.new(
	0,
	|seen, bytes| {
		total = seen + List.len(bytes)
		if total > maximum {
			Err(Reply.status(413))
		} else {
			Ok({ state: total, bytes })
		}
	},
	|_seen| Ok({}),
)

upper = Middleware.ChunkCheck.new(
	{},
	|state, bytes| Ok({ state, bytes: List.map(bytes, |byte| if byte >= 'a' and byte <= 'z' { byte - 32 } else { byte }) }),
	|_state| Ok({}),
)

echo! : Model, RouteContext({}) => Try(Reply, Reply)
echo! = |_model, context| {
	body = Extract.run!(Extract.bytes, context)?
	Ok(Reply.text("${context.request.path}|${Str.from_utf8_lossy(body)}"))
}

Named := { name : Str }.{
	parser_for : _
}

json_name! : Model, RouteContext({}) => Try(Reply, Reply)
json_name! = |_model, context| {
	named : Named
	named = Extract.run!(Extract.json({}), context)?
	Ok(Reply.text(named.name))
}

## Extracts the body twice: the router received it once, so both are equal.
twice! : Model, RouteContext({}) => Try(Reply, Reply)
twice! = |_model, context| {
	first = Extract.run!(Extract.text, context)?
	second = Extract.run!(Extract.text, context)?
	Ok(Reply.text("${first}|${second}"))
}

## Collects the parts as they arrive, and logs why a request was aborted.
count : Handler(Model, [], {})
count = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Ok([]),
	chunk!: |received, bytes| Ok(List.concat(received, bytes)),
	done!: |_model, received| Ok(Reply.text(Str.from_utf8_lossy(received))),
	abort!: |_received, reason| {
		named = match reason {
			Handler.StreamEnd.BadRequest => "BadRequest"
			Handler.StreamEnd.TooLarge => "TooLarge"
			Handler.StreamEnd.TimedOut => "TimedOut"
			Handler.StreamEnd.Failed => "Failed"
			Handler.StreamEnd.Rejected => "Rejected"
		}
		Log.info!("stage-test-abort ${named}")
	},
})
