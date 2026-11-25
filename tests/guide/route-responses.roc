app [program] { pf: platform "../../platform/main.roc" }

import ItemRoutes
import ProtectedRoutes
import pf.IpAddr
import pf.Method
import pf.Request
import pf.RequestBody
import pf.ResponseBody
import pf.Router
import pf.Server
import pf.Version
import pf.RemoteAddr

Model : {}

program = { init!, routes: Router.build(ItemRoutes.routes, {}) }

init! : {} => Try({ model : {}, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	request = {
		method: Method.GET,
		version: Version.Http11,
		raw_target: "/lists/tools/search?q=roc".to_utf8(),
		path: "/lists/tools/search",
		query: "q=roc".to_utf8(),
		headers: [],
		body: RequestBody.Empty,
		remote_addr: RemoteAddr.Unix,
		request_id: "test",
	}
	ok = Router.dispatch!(ItemRoutes.routes, {}, {}, Request.(request))
	body_matches = match ok.body {
		ResponseBody.Bytes(bytes) => bytes == "searching tools for roc, page 1\n".to_utf8()
		ResponseBody.Empty => Bool.False
	}
	if ok.status != 200 or !body_matches {
		return Err(StartupErr("search should return the matching list and query"))
	}
	missing = Router.dispatch!(ItemRoutes.routes, {}, {}, Request.{ ..request, raw_target: request.path.to_utf8(), query: [] })
	if missing.status != 400 {
		return Err(StartupErr("missing search query should return 400"))
	}

	private_path = "/private"
	rejected = Router.dispatch!(ProtectedRoutes.routes, {}, {}, Request.{ ..request, raw_target: private_path.to_utf8(), path: private_path, query: [] })
	if rejected.status != 401 {
		return Err(StartupErr("private route should require an API key"))
	}

	Ok({
		model: {},
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}
