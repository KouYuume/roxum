app [program] { pf: platform "../../platform/main.roc" }

import pf.FileRoot
import pf.Files
import pf.Handler
import pf.HeaderValue
import pf.MethodRouter
import pf.Reply
import pf.ResponseHeader
import pf.HeaderName
import pf.RouteContext
import pf.Router
import pf.Server

## Serves `public/` from the working directory, which the test prepares
##, with `Reply.file` and `Files.serve`, and once more with
## its precompressed files.
Model := { public : FileRoot, precompressed : FileRoot }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	public = match Files.open_root!("public") {
		Ok(root) => root
		Err(_) => return Err(StartupErr("public cannot be opened"))
	}
	precompressed = match Files.open_root_with!("public", Files.RootOptions.{ precompressed: [Files.Precompressed.Brotli, Files.Precompressed.Gzip] }) {
		Ok(root) => root
		Err(_) => return Err(StartupErr("public cannot be opened"))
	}
	Ok({
		model: { public, precompressed },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/files/{*path}", MethodRouter.get(Handler.stateful(serve)))
		.route("/typed/{*path}", MethodRouter.get(Handler.stateful(serve_typed)))
		.route("/quick", MethodRouter.get(Handler.static(|{}| Reply.text("quick"))))
		.route("/serve/{*path}", MethodRouter.get(Files.serve(|model| model.public)))
		.route("/pre/{*path}", MethodRouter.get(Files.serve(|model| model.precompressed)))

serve : Model, RouteContext({}) -> Try(Reply, Reply)
serve = |model, context| Ok(Reply.file(model.public, path_of(context)))

## A `content-type` the app sets wins over the extension's.
serve_typed : Model, RouteContext({}) -> Try(Reply, Reply)
serve_typed = |model, context| {
	value : HeaderValue
	value = "application/x-test"
	Ok(Reply.file(model.public, path_of(context)).with_headers([ResponseHeader.{ name: HeaderName.("content-type"), value }]))
}

path_of : RouteContext({}) -> Str
path_of = |context|
	match List.first(context.path_params) {
		Ok(param) => param.value
		Err(_) => ""
	}
