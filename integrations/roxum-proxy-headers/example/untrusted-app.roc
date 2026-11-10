app [program] {
	pf: platform "../../../platform/main.roc",
	proxy_headers: "../package/main.roc",
}

import pf.Handler
import pf.HeaderName
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Server
import proxy_headers.ProxyHeaders

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: IpAddr.V4((127, 0, 0, 1)),
		port: 0,
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

# Only 10.0.0.0/8 is trusted, so the loopback test client is not a proxy.
routes : Router(Model, [], {})
routes =
	Router.new
		.route("/", MethodRouter.get(Handler.pure(describe)))
		.before_routing(ProxyHeaders.trust(["10.0.0.0/8"]))

# Reports "<address> <port> <scheme> <visible forwarding fields>", counting
# X-Forwarded-*, X-Real-IP, and Forwarded.
describe : RouteContext({}) -> Try(Reply, Reply)
describe = |context| {
	request = context.request
	scheme = match ProxyHeaders.scheme(request) {
		Http => "http"
		Https => "https"
	}
	forwarded = List.count_if(
		request.headers,
		|header| {
			name = HeaderName.inner(header.name)
			Str.starts_with(name, "x-forwarded-") or name == "x-real-ip" or name == "forwarded"
		},
	)
	Ok(Reply.bytes("${format_ip(request.remote_addr.ip)} ${request.remote_addr.port.to_str()} ${scheme} ${forwarded.to_str()}".to_utf8(), "application/octet-stream"))
}

format_ip : IpAddr -> Str
format_ip = |ip|
	match ip {
		V4((a, b, c, d)) => "${a.to_str()}.${b.to_str()}.${c.to_str()}.${d.to_str()}"
		V6((a, b, c, d, e, f, g, h)) => Str.join_with([a, b, c, d, e, f, g, h].map(|group| group.to_str()), ":")
	}
