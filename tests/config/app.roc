app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Server

## The base is next to this file; the test prepares `config/local.toml` in
## the working directory.
Settings : {
	name : Str,
	listen : { port : U16 },
	database : { host : Str, port : U16, replicas : List(Str) },
	log : { level : [Info, Debug], json : Bool },
	timeout_seconds : Try(U32, [Missing]),
}

Model := { settings : Settings }

program = { init!, routes: Router.build(routes, {}) }

## The base alone must decode; a broken base stops the build.
base_settings : Settings
base_settings = Config.check_base(base_text)

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	Ok({
		model: { settings },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: settings.listen.port,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/config", MethodRouter.get(Handler.stateful(|model, _context| Ok(Reply.text(describe(model.settings))))))
		.route("/base", MethodRouter.get(Handler.stateful(|_model, _context| Ok(Reply.text(describe(base_settings))))))

describe : Settings -> Str
describe = |settings| {
	level = match settings.log.level {
		Info => "Info"
		Debug => "Debug"
	}
	timeout = match settings.timeout_seconds {
		Ok(seconds) => seconds.to_str()
		Err(Missing) => "missing"
	}
	lines = [
		"name=${settings.name}",
		"database=${settings.database.host}:${settings.database.port.to_str()}",
		"replicas=${Str.join_with(settings.database.replicas, ",")}",
		"log=${level} json=${if settings.log.json { "true" } else { "false" }}",
		"timeout=${timeout}",
	]
	"${Str.join_with(lines, "\n")}\n"
}
