app [program] {
	pf: platform "../../../platform/main.roc",
	concurrency_limit: "../package/main.roc",
}

import pf.Concurrency
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.ResponseWriter
import pf.Router
import pf.IpAddr
import pf.Server
import pf.Sleep
import concurrency_limit.ConcurrencyLimit

Model := { limiter : Concurrency, small : Concurrency }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	limiter = Concurrency.new!({ max_keys: 1000 })
	small = Concurrency.new!({ max_keys: 2 })
	too_few = Concurrency.new!({ max_keys: 0 })
	too_many = Concurrency.new!({ max_keys: 268_435_457 })
	match (limiter, small, too_few, too_many) {
		(Ok(a), Ok(b), Err(InvalidConcurrency), Err(InvalidConcurrency)) =>
			Ok({
				model: { limiter: a, small: b },
				listen: {
					endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
					timeouts: Server.Timeouts.defaults,
					limits: Server.Limits.defaults,
				},
			})
		_ => Err(StartupErr("the limiters did not come out as expected"))
	}
}

limit_of = |key, limit| ConcurrencyLimit.layer(|model, _head| Ok(ConcurrencyLimit.Check.{ limiter: model.limiter, key, limit, on_full: ConcurrencyLimit.OnFull.Reject }))

# The path's last segment is the key, so requests hold keys of their own.
per_path = |on_full| ConcurrencyLimit.layer(|model, head| Ok(ConcurrencyLimit.Check.{ limiter: model.small, key: head.path, limit: 5, on_full }))

slow! = |_model, _context| {
	Sleep.millis!(400)
	Ok(Reply.text("done"))
}

slow = Handler.effectful(slow!)

crashes! = |_model, _context| crash "this handler stops here"

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/three", MethodRouter.get(slow).layer(limit_of("three", 3)))
		.route("/none", MethodRouter.get(Handler.static(|{}| Reply.empty)).layer(limit_of("none", 0)))
		# Two routes on one key share its limit, and a route of its own has its own.
		.route("/shared-a", MethodRouter.get(slow).layer(limit_of("shared", 1)))
		.route("/shared-b", MethodRouter.get(slow).layer(limit_of("shared", 1)))
		.route("/apart", MethodRouter.get(slow).layer(limit_of("apart", 1)))
		.route("/free", MethodRouter.get(Handler.static(|{}| Reply.text("free"))))
		# A check can decide that this request has no limit.
		.route("/no-limit", MethodRouter.get(slow).layer(ConcurrencyLimit.layer(|_model, _head| Err(NoLimit))))
		.route("/crash", MethodRouter.get(Handler.effectful(crashes!)).layer(limit_of("crash", 1)))
		.route("/stream", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_twice!(writer)))).layer(limit_of("stream", 1)))
		.route("/endless", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_forever!(writer)))).layer(limit_of("endless", 1)))
		.route("/key/{name}", MethodRouter.get(slow).layer(per_path(ConcurrencyLimit.OnFull.Reject)))
		.route("/allow/{name}", MethodRouter.get(slow).layer(per_path(ConcurrencyLimit.OnFull.Allow)))
		.route("/nine", MethodRouter.get(Handler.effectful(hold_nine!)))
		.route("/eight", MethodRouter.get(Handler.effectful(hold_eight!)))

write_twice! = |writer| {
	ResponseWriter.write!(writer, "first".to_utf8())?
	Sleep.millis!(400)
	ResponseWriter.write!(writer, "second".to_utf8())
}

write_forever! = |writer| {
	ResponseWriter.write!(writer, "more".to_utf8())?
	Sleep.millis!(20)
	write_forever!(writer)
}

hold! : Model, U64 => Try({}, [AtLimit, Full])
hold! = |model, count| {
	var $held = 0
	while $held < count {
		Concurrency.acquire!(model.limiter, "many-${$held.to_str()}", 1)?
		$held = $held + 1
	}
	Ok({})
}

hold_eight! = |model, _context|
	match hold!(model, 8) {
		Ok({}) => Ok(Reply.text("eight"))
		Err(_) => Ok(Reply.status(500))
	}

hold_nine! = |model, _context|
	match hold!(model, 9) {
		Ok({}) => Ok(Reply.text("nine"))
		Err(_) => Ok(Reply.status(500))
	}
