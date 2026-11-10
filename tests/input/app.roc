app [program] { pf: platform "../../platform/main.roc" }

import pf.BodyLimit
import pf.Compression
import pf.Extract
import pf.Handler
import pf.HeaderName
import pf.MethodRouter
import pf.Middleware
import pf.Multipart
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Routes
import pf.IpAddr
import pf.Server

## M24 phase 4: handlers with a typed argument, and extractors in a body.
Model := {}

Provided := { user : Try(Str, [Unset]) ?? Err(Unset) }

program = { init!, routes }

init! = |{}|
	Ok({
		model: {},
		listen: {
			address: IpAddr.V4((127, 0, 0, 1)),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

Item := { name : Str, count : U64 }.{
	parser_for : _
}

Search : { q : Str, page : Try(U64, [Missing]), tag : Try(List(Str), [Missing]), on : Try(Bool, [Missing]) }

Agent : { x_agent : Str, x_retry : Try(U64, [Missing]) }

## A field type of the app's: reads what a BeforeBody stage provided.
CurrentUser := Str.{
	parser_for = |_encoding|
		Extract.reading(
			|context|
				match context.provided.user {
					Ok(user) => Ok(CurrentUser.(user))
					Err(Unset) => Err(Reply.status(500))
				},
		)
}

routes : Routes(Model)
routes =
	Router.new
		.route("/query", MethodRouter.get(Handler.typed(query!)))
		.route("/query-optional-str", MethodRouter.get(Handler.typed(query_optional_str!)))
		.route("/query-str", MethodRouter.get(Handler.typed(query_str!)))
		.route("/attempt-json", MethodRouter.post(Handler.typed(attempt_json!)))
		.route("/attempt-pass", MethodRouter.post(Handler.typed(attempt_pass!)))
		.route("/attempt-mixed/{id}", MethodRouter.post(Handler.typed(attempt_mixed!)))
		.route("/form", MethodRouter.post(Handler.typed(form!)))
		.route("/form-early", MethodRouter.post(Handler.typed(form!)).layer(Extract.require_form({})))
		.route("/json", MethodRouter.post(Handler.typed(json!)))
		.route("/items/{id}", MethodRouter.put(Handler.typed(update!)))
		.route("/flags/{on}", MethodRouter.get(Handler.typed(flag!)))
		.route("/no-param", MethodRouter.get(Handler.typed(flag!)))
		.route("/headers", MethodRouter.get(Handler.typed(headers!)))
		.route("/text", MethodRouter.post(Handler.typed(text!)))
		.route("/bytes", MethodRouter.post(Handler.typed(bytes!)))
		.route("/me", MethodRouter.post(Handler.typed(me!)))
		.route("/body", MethodRouter.post(Handler.effectful(in_body!)))
		.route(
			"/decompress",
			MethodRouter.post(Handler.typed(text!))
				.layer(Compression.decompress_requests(16)),
		)
		.route("/profile", MethodRouter.post(Handler.typed(profile!)))
		.route("/profile-early", MethodRouter.post(Handler.typed(profile!)).layer(Extract.require_multipart({})))
		.route("/profile-large", MethodRouter.post(Handler.typed(profile!)).layer(BodyLimit.whole(4 * 1024 * 1024)))
		.route("/upload", MethodRouter.post(Handler.streaming(Multipart.streaming(uploads))))
		.layer([Middleware.Stage.BeforeBody(users)])
		.build(Provided.{})

users = |_model, head|
	match List.find_first(head.headers, |field| field.name == HeaderName.("x-user")) {
		Ok(field) => Ok({ ..head, provided: Provided.{ user: Ok(Str.from_utf8_lossy(field.value)) } })
		Err(_) => Ok(head)
	}

show_search = |search| {
	page = match search.page {
		Ok(number) => number.to_str()
		Err(Missing) => "-"
	}
	tags = match search.tag {
		Ok(values) => Str.join_with(values, ",")
		Err(Missing) => "-"
	}
	on = match search.on {
		Ok(Bool.True) => "true"
		Ok(Bool.False) => "false"
		Err(Missing) => "-"
	}
	"${search.q}|${page}|${tags}|${on}"
}

query_optional_str! : Model, { search : Extract.Query({ count : U64, theme : Try(Str, [Missing]) }) } => Try(Reply, Reply)
query_optional_str! = |_model, { search: Extract.Query.(search) }| {
	theme = match search.theme {
		Ok(value) => value
		Err(Missing) => "none"
	}
	Ok(Reply.text("${search.count.to_str()} ${theme}"))
}

attempt_json! : Model, { item : [Ok(Extract.JsonBody({ name : Str })), Err(Reply)] } => Try(Reply, Reply)
attempt_json! = |_model, { item }|
	match item {
		Ok(Extract.JsonBody.(value)) => Ok(Reply.text("ok ${value.name}"))
		Err(reply) => Ok(Reply.text("err ${reply.status_code().to_str()}"))
	}

attempt_pass! : Model, { item : [Ok(Extract.JsonBody({ name : Str })), Err(Reply)] } => Try(Reply, Reply)
attempt_pass! = |_model, { item }|
	match item {
		Ok(Extract.JsonBody.(value)) => Ok(Reply.text(value.name))
		Err(reply) => Err(reply)
	}

attempt_mixed! : Model, { id : Extract.Path(U64), search : [Ok(Extract.Query({ q : Str })), Err(Reply)], form : [Ok(Extract.Form({ name : Str })), Err(Reply)] } => Try(Reply, Reply)
attempt_mixed! = |_model, { id: Extract.Path.(id), search, form }| {
	query_part = match search {
		Ok(Extract.Query.(value)) => value.q
		Err(reply) => reply.status_code().to_str()
	}
	form_part = match form {
		Ok(Extract.Form.(value)) => value.name
		Err(reply) => reply.status_code().to_str()
	}
	Ok(Reply.text("${id.to_str()} ${query_part} ${form_part}"))
}

query_str! : Model, { search : Extract.Query({ count : U64, theme : Str }) } => Try(Reply, Reply)
query_str! = |_model, { search: Extract.Query.(search) }| Ok(Reply.text("${search.count.to_str()} ${search.theme}"))

query! : Model, { search : Extract.Query(Search) } => Try(Reply, Reply)
query! = |_model, { search: Extract.Query.(search) }| Ok(Reply.text(show_search(search)))

form! : Model, { search : Extract.Form(Search) } => Try(Reply, Reply)
form! = |_model, { search: Extract.Form.(search) }| Ok(Reply.text(show_search(search)))

json! : Model, { item : Extract.JsonBody(Item) } => Try(Reply, Reply)
json! = |_model, { item: Extract.JsonBody.(item) }| Ok(Reply.text("${item.name}:${item.count.to_str()}"))

## Three fields of different kinds, in any order.
update! : Model, { item : Extract.JsonBody(Item), id : Extract.Path(U64), search : Extract.Query({ q : Str }) } => Try(Reply, Reply)
update! = |_model, { item: Extract.JsonBody.(item), id: Extract.Path.(id), search: Extract.Query.(search) }|
	Ok(Reply.text("${id.to_str()}:${item.name}:${search.q}"))

flag! : Model, { on : Extract.Path(Bool) } => Try(Reply, Reply)
flag! = |_model, { on: Extract.Path.(on) }| Ok(
	Reply.text(
		if on {
			"yes"
		} else {
			"no"
		},
	),
)

headers! : Model, { agent : Extract.Headers(Agent) } => Try(Reply, Reply)
headers! = |_model, { agent: Extract.Headers.(agent) }| {
	retry = match agent.x_retry {
		Ok(count) => count.to_str()
		Err(Missing) => "-"
	}
	Ok(Reply.text("${agent.x_agent}:${retry}"))
}

text! : Model, { body : Extract.Text } => Try(Reply, Reply)
text! = |_model, { body: Extract.Text.(body) }| Ok(Reply.text(body))

bytes! : Model, { body : Extract.Bytes } => Try(Reply, Reply)
bytes! = |_model, { body: Extract.Bytes.(body) }| Ok(Reply.text(body.len().to_str()))

me! : Model, { user : CurrentUser, item : Extract.JsonBody(Item) } => Try(Reply, Reply)
me! = |_model, { user: CurrentUser.(user), item: Extract.JsonBody.(item) }| Ok(Reply.text("${user}:${item.name}"))

Profile : { title : Str, count : Try(U64, [Missing]), icon : Extract.Upload, tags : Try(List(Str), [Missing]) }

profile! : Model, { form : Extract.Multipart(Profile) } => Try(Reply, Reply)
profile! = |_model, { form: Extract.Multipart.(form) }| {
	filename = match form.icon.filename {
		Ok(name) => name
		Err(NoFilename) => "-"
	}
	kind = match form.icon.content_type {
		Ok(value) => value
		Err(NoContentType) => "-"
	}
	tags = match form.tags {
		Ok(values) => Str.join_with(values, ",")
		Err(Missing) => "-"
	}
	Ok(Reply.text("${form.title}|${filename}|${kind}|${form.icon.bytes.len().to_str()}|${tags}"))
}

## Reports each field and how many bytes it had, holding only a count.
uploads = Multipart.Callbacks.{
	begin!: |_model, _head| Ok({ done: "", name: "", bytes: 0 }),
	field!: |state, head| Ok({ done: closed(state), name: head.name, bytes: 0 }),
	chunk!: |state, bytes| Ok({ ..state, bytes: state.bytes + List.len(bytes) }),
	done!: |_model, state| Ok(Reply.text(closed(state))),
}

closed = |state| if Str.is_empty(state.name) {
	state.done
} else {
	"${state.done}${state.name}=${state.bytes.to_str()};"
}

in_body! : Model, RouteContext(Provided) => Try(Reply, Reply)
in_body! = |_model, context| {
	item : Item
	item = Extract.run!(Extract.json({}), context)?
	search : { q : Str }
	search = Extract.run!(Extract.query({}), context)?
	Ok(Reply.text("${item.name}:${search.q}"))
}
