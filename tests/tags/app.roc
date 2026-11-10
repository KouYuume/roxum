app [program] { pf: platform "../../platform/main.roc" }

import pf.Extract
import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.Middleware
import pf.MethodRouter
import pf.Reply
import pf.ResponseHeader
import pf.RouteContext
import pf.Router
import pf.Routes
import pf.IpAddr
import pf.Server

## M24 phase 3: route tags read by a layer, and values a layer provides.
Model := {}

Tag : [Limit(U64), Members, Guests, Open]

Provided := {
	user : Try(Str, [Unset, Anonymous]) ?? Err(Unset),
}

Context : RouteContext(Provided)

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

routes : Routes(Model)
routes =
	Router.new
		.route("/open", MethodRouter.get(Handler.effectful(tag_count!)))
		.route(
			"/article",
			MethodRouter.methods([
				MethodRouter.get(Handler.effectful(whoami!)).tags([Limit(100)]),
				MethodRouter.delete(Handler.effectful(whoami!)).tags([Limit(5)]),
			]).tags([Members]),
		)
		# No stage provides the user here: 500, not an anonymous request.
		.route("/forgot", MethodRouter.get(Handler.effectful(whoami!)))
		.route("/page", MethodRouter.get(Handler.effectful(greeting!)).tags([Guests]))
		.route("/page-forgot", MethodRouter.get(Handler.effectful(greeting!)))
		.nest("/nested", nested)
		# Written first, so outermost: it also sees the 401 from `users`.
		.layer(limits)
		.layer(users)
		.build(Provided.{})

## A nested router's tags stay on its routes, and a 405 sees add_tags only.
nested =
	Router.new
		.route("/a", MethodRouter.get(Handler.effectful(tag_count!)).tags([Limit(1)]))
		.add_tags([Open])

users : List(Middleware.Stage(Model, Tag, Provided))
users = [
	Middleware.Stage.BeforeBody(
		|_model, head| {
			key = List.find_first(head.headers, |field| field.name == HeaderName.("x-user"))
			user = match key {
				Ok(field) => Ok(Str.from_utf8_lossy(field.value))
				Err(_) => Err(Anonymous)
			}
			if List.contains(head.tags, Members) and user == Err(Anonymous) {
				Err(Reply.status(401))
			} else if List.contains(head.tags, Members) or List.contains(head.tags, Guests) {
				Ok({ ..head, provided: Provided.{ user } })
			} else {
				Ok(head)
			}
		},
	),
]

## Reports the route's limit and how many tags it has.
limits : List(Middleware.Stage(Model, Tag, Provided))
limits = [
	Middleware.Stage.AfterHandler(
		|_model, head, reply| {
			var $limit = 0
			for tag in head.tags {
				match tag {
					Limit(count) => { $limit = count }
					Members | Guests | Open => {}
				}
			}
			limit = $limit
			Reply.with_headers(reply, [header("x-limit", limit.to_str()), header("x-tags", head.tags.len().to_str())])
		},
	),
]

header = |name, value|
	match HeaderValue.from_str(value) {
		Ok(field) => ResponseHeader.{ name: if name == "x-limit" { HeaderName.("x-limit") } else { HeaderName.("x-tags") }, value: field }
		Err(_) => crash "tag test header value has a line break"
	}

whoami! : Model, Context => Try(Reply, Reply)
whoami! = |_model, context| {
	user = Extract.run!(Extract.provided(|p| p.user), context)?
	Ok(Reply.text(user))
}

greeting! : Model, Context => Try(Reply, Reply)
greeting! = |_model, context| {
	user = Extract.run!(Extract.optional(|p| p.user), context)?
	match user {
		Ok(name) => Ok(Reply.text("hello ${name}"))
		Err(Anonymous) => Ok(Reply.text("hello guest"))
	}
}

tag_count! : Model, Context => Try(Reply, Reply)
tag_count! = |_model, _context| Ok(Reply.text("ok"))
