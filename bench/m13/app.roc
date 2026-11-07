app [program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Extract
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Server

## The comparison server. axum/ and go/ implement the same routes.

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	remote = match File.read_utf8!("benchmark-remote", 8) {
		Ok("enabled\n") => True
		Err(FileNotFound) => False
		_ => return Err(StartupErr("benchmark-remote must contain enabled followed by a newline"))
	}
	Ok({
		model: {},
		listen: {
			address: if remote { Server.Ipv4Address.(0, 0, 0, 0) } else { Server.Ipv4Address.(127, 0, 0, 1) },
			port: if remote { 8080 } else { 0 },
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes = {
	base =
		Router.new
			.route("/plaintext", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, World!"))))
			.route("/json", MethodRouter.get(Handler.static(|{}| Reply.bytes("{\"message\":\"Hello, World!\"}".to_utf8(), "application/json"))))
			.route("/echo", MethodRouter.post(Handler.typed(echo!)))
	add_items(base, 0)
}

## 100 routes that differ in their first segment; the bench requests one of them.
add_items : Router(Model, [], {}), U64 -> Router(Model, [], {})
add_items = |router, index|
	if index == 100 {
		router
	} else {
		add_items(Router.route(router, "/r${index.to_str()}/items/{id}", MethodRouter.get(Handler.pure(item))), index + 1)
	}

item : RouteContext({}) -> Try(Reply, Reply)
item = |context|
	match List.first(context.path_params) {
		Ok(param) => Ok(Reply.text(param.value))
		Err(_) => Ok(Reply.text(""))
	}

echo! : Model, { body : Extract.Bytes } => Try(Reply, Reply)
echo! = |_model, { body: Extract.Bytes.(body) }| Ok(Reply.bytes(body, "application/octet-stream"))
