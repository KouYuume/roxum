app [program] {
	pf: platform "../../../platform/main.roc",
	rate_limit: "../package/main.roc",
}

import pf.Extract
import pf.Handler
import pf.MethodRouter
import pf.RateCounter
import pf.Reply
import pf.RequestHead
import pf.RouteContext
import pf.Router
import pf.Server
import rate_limit.RateLimit

Model := { per_hour : RateCounter, short : RateCounter, small : RateCounter }

Tag : [Limit(U64), Other(U64), Short(U64), Small(U64, RateLimit.OnFull)]

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	per_hour = RateCounter.new!({ window_seconds: 3600, max_keys: 1000 })
	short = RateCounter.new!({ window_seconds: 2, max_keys: 1000 })
	small = RateCounter.new!({ window_seconds: 3600, max_keys: 2 })
	refused = RateCounter.new!({ window_seconds: 0, max_keys: 1 })
	match (per_hour, short, small, refused) {
		(Ok(a), Ok(b), Ok(c), Err(InvalidRateCounter)) =>
			Ok({
				model: { per_hour: a, short: b, small: c },
				listen: {
					address: Server.Ipv4Address.(127, 0, 0, 1),
					port: 0,
					timeouts: Server.Timeouts.defaults,
					limits: Server.Limits.defaults,
				},
			})
		_ => Err(StartupErr("the counters did not come out as expected"))
	}
}

ok = Handler.static(|{}| Reply.text("ok"))

routes : Router(Model, Tag, {})
routes =
	Router.new
		.route("/free", MethodRouter.get(ok))
		.route("/limited", MethodRouter.get(ok).tags([Limit(3)]))
		.route("/other", MethodRouter.get(ok).tags([Other(1)]))
		.route("/two", MethodRouter.get(ok).tags([Limit(100), Other(1)]))
		.route("/short", MethodRouter.get(ok).tags([Short(2)]))
		.route("/full-allow", MethodRouter.get(ok).tags([Small(100, RateLimit.OnFull.Allow)]))
		.route("/full-reject", MethodRouter.get(ok).tags([Small(100, RateLimit.OnFull.Reject)]))
		.layer(RateLimit.layer(check_for))
		# Not behind the layer: it counts failures only.
		.route("/login/{password}", MethodRouter.get(Handler.effectful(login!)))

check_for : Model, RequestHead(Tag, {}), Tag -> Try(RateLimit.Check, [NoLimit])
check_for = |model, head, tag| {
	ip = RateLimit.client_ip(head.remote_addr.ip)
	match tag {
		Limit(limit) => Ok(RateLimit.Check.{ counter: model.per_hour, key: "limit:${ip}", limit, on_full: RateLimit.OnFull.Reject })
		Other(limit) => Ok(RateLimit.Check.{ counter: model.per_hour, key: "other:${ip}", limit, on_full: RateLimit.OnFull.Reject })
		Short(limit) => Ok(RateLimit.Check.{ counter: model.short, key: ip, limit, on_full: RateLimit.OnFull.Reject })
		Small(limit, on_full) => Ok(RateLimit.Check.{ counter: model.small, key: Str.from_utf8_lossy(head.query), limit, on_full })
	}
}

## Two wrong passwords, and even the right one is refused.
login! : Model, RouteContext({}) => Try(Reply, Reply)
login! = |model, context| {
	check = RateLimit.Check.{ counter: model.per_hour, key: "login:alice", limit: 2, on_full: RateLimit.OnFull.Reject }
	RateLimit.peek!(check)?
	password = Extract.run!(Extract.path_param("password"), context)?
	if password == "right" {
		Ok(Reply.text("welcome"))
	} else {
		_ = RateCounter.add!(check.counter, check.key, 1)
		Err(Reply.status(401))
	}
}
