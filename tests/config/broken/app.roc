app [program] { pf: platform "../../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Router
import pf.Server

Settings : { database : { host : Str, port : U16 } }

Model := { settings : Settings }

program = { init!, routes: Router.build(routes, {}) }

## Decoded while compiling: the incomplete base stops the build.
base_settings : Settings
base_settings = Config.check_base(base_text)

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}|
	Ok({
		model: { settings: base_settings },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})

routes : Router(Model, [], {})
routes = Router.new
