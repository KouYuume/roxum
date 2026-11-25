app [program] { pf: platform "../../platform/main.roc" }

import ItemRoutes
import pf.Router
import pf.IpAddr
import pf.Server

Model : {}

program = { init!, routes: Router.build(ItemRoutes.routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})
