app [program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Files
import pf.FileRoot
import pf.HeaderName
import pf.Middleware
import pf.ResponseHeader
import pf.Extract
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server

## axum/ implements the same routes; go/ implements the original six workloads.

Model := { files : FileRoot }

Provided := { source : Str }

program = { init!, routes: Router.build(routes, Provided.{ source: "" }) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	remote = match File.read_utf8!("benchmark-remote", 8) {
		Ok("enabled\n") => True
		Err(FileNotFound) => False
		_ => return Err(StartupErr("benchmark-remote must contain enabled followed by a newline"))
	}
	Ok({
		model: { files: Files.open_root!(".").map_err(|_| StartupErr("cannot open benchmark working directory"))? },
		listen: {
			endpoint: Server.Endpoint.Tcp({
				address: if remote {
					IpAddr.V4((0, 0, 0, 0))
				} else {
					IpAddr.V4((127, 0, 0, 1))
				},
				port: if remote {
					8080
				} else {
					0
				},
			}),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], Provided)
routes = {
	base =
		Router.new
			.route("/plaintext", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, World!"))))
			.route("/json", MethodRouter.get(Handler.static(|{}| Reply.bytes("{\"message\":\"Hello, World!\"}".to_utf8(), "application/json"))))
			.route(
				"/dynamic/{id}",
				MethodRouter.get(Handler.pure(dynamic)).layer([
					Middleware.Stage.BeforeBody(
						|_model, head| {
							field = List.find_first(head.headers, |each| each.name == HeaderName.("x-bench-source")).map_err(|_| Reply.text("missing source").with_status(400))?
							source = Str.from_utf8(field.value).map_err(|_| Reply.text("invalid source").with_status(400))?
							Ok({ ..head, provided: Provided.{ source } })
						},
					),
					Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("x-bench-layer"), value: "active" }])),
				]),
			)
			.route("/file-64k", MethodRouter.get(Handler.stateful(|model, _context| Ok(Reply.file(model.files, "bench-payload.bin")))))
			.route("/echo", MethodRouter.post(Handler.typed(echo!)))
	add_items(base, 0)
}

## 100 routes that differ in their first segment; the bench requests one of them.
add_items : Router(Model, [], Provided), U64 -> Router(Model, [], Provided)
add_items = |router, index|
	if index == 100 {
		router
	} else {
		add_items(Router.route(router, "/r${index.to_str()}/items/{id}", MethodRouter.get(Handler.pure(item))), index + 1)
	}

item : RouteContext(Provided) -> Try(Reply, Reply)
item = |context|
	match List.first(context.path_params) {
		Ok(param) => Ok(Reply.text(param.value))
		Err(_) => Ok(Reply.text(""))
	}

dynamic : RouteContext(Provided) -> Try(Reply, Reply)
dynamic = |context| {
	id = List.first(context.path_params).map_err(|_| Reply.text("missing id").with_status(400))?
	Ok(Reply.json([id.value, context.provided.source]))
}

echo! : Model, { body : Extract.Bytes } => Try(Reply, Reply)
echo! = |_model, { body: Extract.Bytes.(body) }| Ok(Reply.bytes(body, "application/octet-stream"))
