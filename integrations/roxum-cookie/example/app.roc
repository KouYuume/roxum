app [program] {
	pf: platform "../../../platform/main.roc",
	cookie: "../package/main.roc",
}

import cookie.Cookie
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Secret
import pf.IpAddr
import pf.Server

Model := { keys : Cookie.Keys }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	current = match Secret.from_env!("ROXUM_COOKIE_KEY") {
		Ok(secret) => secret
		Err(_) => return Err(StartupErr("ROXUM_COOKIE_KEY is not set"))
	}
	previous = match Secret.from_env!("ROXUM_COOKIE_OLD_KEY") {
		Ok(secret) => secret
		Err(_) => return Err(StartupErr("ROXUM_COOKIE_OLD_KEY is not set"))
	}
	Ok({
		model: { keys: Cookie.Keys.{ current, previous: [previous] } },
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/set", MethodRouter.get(Handler.static(|{}| defaults)))
		.route("/set-all", MethodRouter.get(Handler.static(|{}| every_attribute)))
		.route("/set-encoded", MethodRouter.get(Handler.static(|{}| encoded)))
		.route("/set-two", MethodRouter.get(Handler.static(|{}| two)))
		.route("/remove", MethodRouter.get(Handler.static(|{}| removed)))
		.route("/remove-host", MethodRouter.get(Handler.static(|{}| removed_prefixed)))
		.route("/refused", MethodRouter.get(Handler.static(|{}| refused)))
		.route("/get", MethodRouter.get(Handler.pure(get)))
		.route("/typed", MethodRouter.get(Handler.typed(typed!)))
		.route("/sign", MethodRouter.get(Handler.effectful(sign!)))
		.route("/verified", MethodRouter.get(Handler.effectful(verified!)))

defaults : Reply
defaults = Reply.text("ok") |> Cookie.add(Cookie.{ name: "theme", value: "dark" }) ?? Reply.status(500)

every_attribute : Reply
every_attribute = {
	cookie = Cookie.{
		name: "a",
		value: "b",
		path: "/app",
		domain: Cookie.Domain.Of("example.com"),
		max_age: Cookie.MaxAge.Seconds(3600),
		same_site: Cookie.SameSite.Strict,
		secure: Bool.False,
		http_only: Bool.False,
	}
	Reply.text("ok") |> Cookie.add(cookie) ?? Reply.status(500)
}

encoded : Reply
encoded = Reply.text("ok") |> Cookie.add(Cookie.{ name: "note", value: "a b;é%" }) ?? Reply.status(500)

two : Reply
two = {
	first = Reply.text("ok") |> Cookie.add(Cookie.{ name: "a", value: "1" }) ?? Reply.status(500)
	first |> Cookie.add(Cookie.{ name: "b", value: "2" }) ?? Reply.status(500)
}

removed : Reply
removed = Reply.text("ok") |> Cookie.remove(Cookie.Removal.{ name: "theme" }) ?? Reply.status(500)

removed_prefixed : Reply
removed_prefixed = Reply.text("ok") |> Cookie.remove(Cookie.Removal.{ name: "__Host-a" }) ?? Reply.status(500)

# Each failure of `Cookie.add`, by name.
refused : Reply
refused = {
	base = Reply.text("ok")
	results = [
		(base |> Cookie.add(Cookie.{ name: "a b", value: "x" })),
		(base |> Cookie.add(Cookie.{ name: "a", value: "x", path: "no-slash" })),
		(base |> Cookie.add(Cookie.{ name: "a", value: "x", path: "/;Secure" })),
		(base |> Cookie.add(Cookie.{ name: "a", value: "x", domain: Cookie.Domain.Of("a;b") })),
		(base |> Cookie.add(Cookie.{ name: "a", value: Str.join_with(List.repeat("x", 4096), "") })),
		(base |> Cookie.add(Cookie.{ name: "a", value: "x", same_site: Cookie.SameSite.None, secure: Bool.False })),
		(base |> Cookie.add(Cookie.{ name: "__Secure-a", value: "x", secure: Bool.False })),
		(base |> Cookie.add(Cookie.{ name: "__Host-a", value: "x", path: "/app" })),
	]
	names = results.map(
		|result|
			match result {
				Ok(_) => "accepted"
				Err(InvalidName) => "name"
				Err(InvalidPath) => "path"
				Err(InvalidDomain) => "domain"
				Err(TooLarge) => "large"
				Err(RefusedByBrowsers) => "refused"
			},
	)
	Reply.text(Str.join_with(names, ","))
}

get : RouteContext({}) -> Try(Reply, Reply)
get = |context|
	match Cookie.get(context.request.headers, "theme") {
		Ok(value) => Ok(Reply.text(value))
		Err(NotFound) => Err(Reply.status(404))
	}

typed! : Model, { cookies : Cookie.Read({ count : U64, theme : Try(Str, [Missing]) }) } => Try(Reply, Reply)
typed! = |_model, { cookies: Cookie.Read.(cookies) }| {
	theme = match cookies.theme {
		Ok(value) => value
		Err(Missing) => "none"
	}
	Ok(Reply.text("${cookies.count.to_str()} ${theme}"))
}

sign! : Model, RouteContext({}) => Try(Reply, Reply)
sign! = |model, _context|
	match Cookie.sign!(Cookie.{ name: "user", value: "42" }, model.keys) {
		Ok(signed) => Ok(Reply.text("ok") |> Cookie.add(signed) ?? Reply.status(500))
		Err(SigningFailed) => Err(Reply.status(500))
	}

verified! : Model, RouteContext({}) => Try(Reply, Reply)
verified! = |model, context|
	match Cookie.verified!(context.request.headers, model.keys, "user") {
		Ok(value) => Ok(Reply.text(value))
		Err(NotFound) => Err(Reply.status(404))
		Err(BadSignature) => Err(Reply.status(401))
		Err(SigningFailed) => Err(Reply.status(500))
	}
