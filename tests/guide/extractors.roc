app [program] { pf: platform "../../platform/main.roc" }

import pf.Extract
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

# ANCHOR: types
## The JSON body `{"name": "..."}`. `parser_for` lets Roc derive the decoder.
NewItem := { name : Str }.{
	parser_for : _
}

# ANCHOR_END: types

# ANCHOR: routes
routes : Router(Model, [], {})
routes =
	Router.new
		.route(
			"/lists/{list}/items",
			MethodRouter.post(Handler.typed(add_item!))
			# Refuses a non-JSON Content-Type before the body is received.
				.layer(Extract.require_json({})),
		)
		.route("/lists/{list}/search", MethodRouter.get(Handler.typed(search!)))
		.route("/lists/{list}/raw", MethodRouter.get(Handler.effectful(raw_search!)))

## The argument's field types say what to read; the field `list` reads the path
## parameter of that name. A field that cannot be read answers with its error
## and the handler does not run.
add_item! : Model, { list : Extract.Path(Str), item : Extract.JsonBody(NewItem) } => Try(Reply, Reply)
add_item! = |_model, { list: Extract.Path.(list), item: Extract.JsonBody.(item) }|
	Ok(Reply.text("added ${item.name} to ${list}\n").with_status(201))

search! : Model, { list : Extract.Path(Str), search : Extract.Query({ q : Str, page : Try(U64, [Missing]) }) } => Try(Reply, Reply)
search! = |_model, { list: Extract.Path.(list), search: Extract.Query.(search) }| {
	page = match search.page {
		Ok(number) => number.to_str()
		Err(Missing) => "1"
	}
	Ok(Reply.text("searching ${list} for ${search.q}, page ${page}\n"))
}

## Extractors can also be run in the handler's body, on a `RouteContext`.
raw_search! : Model, RouteContext({}) => Try(Reply, Reply)
raw_search! = |_model, context| {
	list = Extract.run!(Extract.path_param("list"), context)?
	query = Extract.run!(Extract.query_str, context)?
	Ok(Reply.text("raw ${list} ${query}\n"))
}
# ANCHOR_END: routes
