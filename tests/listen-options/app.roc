app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

## `config/local.toml` in the working directory chooses the thread and
## process counts and the drain timeout; a left-out key keeps `Auto` or the
## default.
Settings : {
	threads : Try(U16, [Missing]),
	processes : Try(U16, [Missing]),
	drain_timeout_milliseconds : Try(U64, [Missing]),
}

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	threads = match settings.threads {
		Ok(count) => Server.Threads.Fixed(count)
		Err(Missing) => Server.Threads.Auto
	}
	processes = match settings.processes {
		Ok(count) => count
		Err(Missing) => 1
	}
	address = IpAddr.V4((127, 0, 0, 1))
	listen = match settings.drain_timeout_milliseconds {
		Ok(milliseconds) => Server.ListenOptions.{
			address,
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads,
			processes,
			drain_timeout_milliseconds: milliseconds,
		}
		# Leaves the defaulted field out.
		Err(Missing) => Server.ListenOptions.{ address, port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults, threads, processes }
	}
	Ok({ model: {}, listen })
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.stateful(|_model, _context| Ok(Reply.text("ok\n")))))
