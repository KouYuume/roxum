app [program] { pf: platform "../../platform/main.roc" }

import pf.BodyLimit
import pf.Compression
import pf.Extract
import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.MethodRouter
import pf.Middleware
import pf.Redirect
import pf.Reply
import pf.ResponseHeader
import pf.RouteContext
import pf.Router
import pf.Server

## The routes of `tools/axum-contract/src/main.rs`, in roxum. `compare.py` sends
## both the same requests.
Model := {}

Item := { name : Str }.{
	parser_for : _
}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
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
		.route("/before", MethodRouter.get(text))
		.layer([mark(HeaderName.("x-layer"), "outer")])
		.route("/text", MethodRouter.get(text))
		.route("/json", MethodRouter.post(Handler.typed(read_json!)))
		.route("/json-reply", MethodRouter.get(Handler.static(|{}| Reply.json({ name: "a" }))))
		.route("/query", MethodRouter.get(Handler.typed(query!)))
		.route("/form", MethodRouter.post(Handler.typed(form!)))
		.route("/upload", MethodRouter.post(Handler.typed(upload!)))
		.route("/items/{id}", MethodRouter.get(Handler.typed(item!)))
		.route("/words/{word}", MethodRouter.get(Handler.typed(word!)))
		.route("/rest/{*tail}", MethodRouter.get(Handler.typed(rest!)))
		.route("/limited", MethodRouter.post(Handler.typed(length!)).layer(BodyLimit.whole(1024)))
		.route("/created", MethodRouter.get(Handler.static(|{}| Reply.status(201))))
		.route("/see-other", MethodRouter.get(Handler.static(|{}| Redirect.see_other("/done") ?? Reply.status(500))))
		.route("/temporary", MethodRouter.get(Handler.static(|{}| Redirect.temporary("/done") ?? Reply.status(500))))
		.route("/permanent", MethodRouter.get(Handler.static(|{}| Redirect.permanent("/done") ?? Reply.status(500))))
		.route(
			"/methods",
			MethodRouter.methods([
				MethodRouter.get(Handler.pure(method_name)),
				MethodRouter.delete(Handler.pure(method_name)),
			]),
		)
		.route("/delete-only", MethodRouter.delete(Handler.pure(method_name)))
		.route(
			"/refused",
			MethodRouter.get(text)
				.layer([Middleware.Stage.BeforeBody(|_model, _head| Err(Reply.status(403)))]),
		)
		.route(
			"/sized/{size}",
			MethodRouter.get(Handler.typed(sized!))
				.layer(Compression.layer(Compression.Options.{})),
		)
		.nest("/api", nested)
		.nest("/plain", plain)
		.fallback(|reason, _model, _head| fallback_reply(reason, "root fallback"))

nested : Router(Model, [], {})
nested =
	Router.new
		.route("/items/{id}", MethodRouter.get(Handler.typed(item!)))
		.layer([mark(HeaderName.("x-nested"), "yes")])
		.fallback(|reason, _model, _head| fallback_reply(reason, "nested fallback"))

plain : Router(Model, [], {})
plain =
	Router.new
		.route("/items/{id}", MethodRouter.get(Handler.typed(item!)))

## Only what could not be routed: a 405 and a 400 keep roxum's own answer.
fallback_reply = |reason, body|
	match reason {
		Router.Unmatched.NotFound => Ok(Reply.text(body).with_status(404))
		Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.status(405))
		Router.Unmatched.BadPath => Ok(Reply.status(400))
	}

mark = |name, value|
	Middleware.Stage.AfterHandler(
		|_model, _head, reply|
			match HeaderValue.from_str(value) {
				Ok(header) => Reply.with_headers(reply, [ResponseHeader.{ name, value: header }])
				Err(_) => reply
			},
	)

text = Handler.static(|{}| Reply.text("hello"))

read_json! : Model, { item : Extract.JsonBody(Item) } => Try(Reply, Reply)
read_json! = |_model, { item: Extract.JsonBody.(item) }| Ok(Reply.text(item.name))

query! : Model, { search : Extract.Query({ q : Str, page : Try(U64, [Missing]) }) } => Try(Reply, Reply)
query! = |_model, { search: Extract.Query.(search) }| {
	page = match search.page {
		Ok(number) => number.to_str()
		Err(Missing) => "-"
	}
	Ok(Reply.text("${search.q} ${page}"))
}

form! : Model, { form : Extract.Form({ name : Str }) } => Try(Reply, Reply)
form! = |_model, { form: Extract.Form.(form) }| Ok(Reply.text(form.name))

upload! : Model, { form : Extract.Multipart({ name : Str }) } => Try(Reply, Reply)
upload! = |_model, { form: Extract.Multipart.(form) }| Ok(Reply.text(form.name))

item! : Model, { id : Extract.Path(U64) } => Try(Reply, Reply)
item! = |_model, { id: Extract.Path.(id) }| Ok(Reply.text(id.to_str()))

word! : Model, { word : Extract.Path(Str) } => Try(Reply, Reply)
word! = |_model, { word: Extract.Path.(word) }| Ok(Reply.text(word))

rest! : Model, { tail : Extract.Path(Str) } => Try(Reply, Reply)
rest! = |_model, { tail: Extract.Path.(tail) }| Ok(Reply.text(tail))

length! : Model, { body : Extract.Bytes } => Try(Reply, Reply)
length! = |_model, { body: Extract.Bytes.(body) }| Ok(Reply.text(body.len().to_str()))

sized! : Model, { size : Extract.Path(U64) } => Try(Reply, Reply)
sized! = |_model, { size: Extract.Path.(size) }| Ok(Reply.text(Str.join_with(List.repeat("x", size), "")))

method_name : RouteContext({}) -> Try(Reply, Reply)
method_name = |context| Ok(Reply.text(context.request.method.to_str()))
