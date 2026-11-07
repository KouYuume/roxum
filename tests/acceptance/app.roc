app [program] { pf: platform "../../platform/main.roc" }

import pf.BodyLimit
import pf.Compression
import pf.Extract
import pf.FileRoot
import pf.Files
import pf.Handler
import pf.MethodRouter
import pf.Middleware
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Server
import pf.Sleep

## The boundaries of `reports/2026-11-01-axum-parity-review.md`'s acceptance
## contracts that other tests do not walk one by one.
Model := { public : FileRoot }

Item := { name : Str }.{
	parser_for : _
}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	public = match Files.open_root!("public") {
		Ok(root) => root
		Err(_) => return Err(StartupErr("public cannot be opened"))
	}
	Ok({
		model: { public },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: { ..Server.Timeouts.defaults, request_body_milliseconds: 500 },
			limits: Server.Limits.{ maximum_requests_in_progress: Server.Count.Fixed(3) },
			threads: Server.Threads.Fixed(2),
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/json", MethodRouter.post(Handler.effectful(json!)))
		.route(
			"/whole",
			MethodRouter.post(Handler.effectful(twice!))
				.layer(BodyLimit.whole(1024)),
		)
		# Past what the host reads ahead (64 KiB), and read twice.
		.route(
			"/ahead",
			MethodRouter.post(Handler.effectful(twice!))
				.layer(BodyLimit.whole(1_000_000)),
		)
		.route(
			"/ahead-refused",
			MethodRouter.post(Handler.effectful(twice!))
				.layer([Middleware.Stage.BeforeBody(|_model, _head| Err(Reply.status(403)))]),
		)
		.route(
			"/stream",
			MethodRouter.post(counted)
				.layer(BodyLimit.streamed(Server.BodyLimit.Bytes(70_000))),
		)
		.route(
			"/stream-unlimited",
			MethodRouter.post(counted)
				.layer(BodyLimit.streamed(Server.BodyLimit.Unlimited)),
		)
		.route("/path/static", MethodRouter.get(Handler.pure(|_context| Ok(Reply.text("static")))))
		.route("/path/{id}", MethodRouter.get(Handler.pure(param("id"))))
		.route("/path/{id}/edit", MethodRouter.get(Handler.pure(param("id"))))
		.route("/rest/{*tail}", MethodRouter.get(Handler.pure(param("tail"))))
		.route("/files/{*path}", MethodRouter.get(Files.serve(|model| model.public)))
		.route(
			"/sized/{bytes}",
			MethodRouter.get(Handler.pure(sized))
				.layer(Compression.layer(Compression.Options.{ above_bytes: 100 })),
		)
		.route("/sleep/{ms}", MethodRouter.get(Handler.effectful(sleep!)))

json! : Model, RouteContext({}) => Try(Reply, Reply)
json! = |_model, context| {
	item : Item
	item = Extract.run!(Extract.json({}), context)?
	Ok(Reply.text(item.name))
}

## The length and whether a second read gives the same bytes.
twice! : Model, RouteContext({}) => Try(Reply, Reply)
twice! = |_model, context| {
	first = Extract.run!(Extract.bytes, context)?
	second = Extract.run!(Extract.bytes, context)?
	Ok(Reply.text("${first.len().to_str()} ${if first == second { "same" } else { "differs" }}"))
}

counted = Handler.streaming(Handler.Streaming.{
	begin!: |_model, _head| Ok(0),
	chunk!: |total, bytes| Ok(total + bytes.len()),
	done!: |_model, total| Ok(Reply.text(total.to_str())),
})

param : Str -> (RouteContext({}) -> Try(Reply, Reply))
param = |name| |context|
	match List.find_first(context.path_params, |entry| entry.name == name) {
		Ok(found) => Ok(Reply.text("${name}=${found.value}"))
		Err(_) => Err(Reply.status(500))
	}

sized : RouteContext({}) -> Try(Reply, Reply)
sized = |context|
	match List.first(context.path_params) {
		Ok(found) => Ok(Reply.text(Str.join_with(List.repeat("x", U64.from_str(found.value) ?? 0), "")))
		Err(_) => Err(Reply.status(500))
	}

sleep! : Model, RouteContext({}) => Try(Reply, Reply)
sleep! = |_model, context| {
	milliseconds = Extract.run!(Extract.path_param("ms"), context)?
	Sleep.millis!(U64.from_str(milliseconds) ?? 0)
	Ok(Reply.text("slept"))
}
