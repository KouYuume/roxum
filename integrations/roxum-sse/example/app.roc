app [program] {
	pf: platform "../../../platform/main.roc",
	sse: "../package/main.roc",
}

import pf.Handler
import pf.Instant
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import pf.Sleep
import sse.Sse

Model := {}

program = {
	init!,
	routes: Router.build(routes, {}),
}

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

routes : Router(Model, [], {})
routes = Router.new
	.route("/events", MethodRouter.get(Handler.pure(events)))
	.route("/large", MethodRouter.get(Handler.pure(large_event)))
	.route("/ticks", MethodRouter.get(Handler.pure(ticks)))
	.route("/quiet", MethodRouter.get(Handler.pure(quiet)))

## An event every 100 ms without end, numbered by its `id`. A client that
## connects again goes on after the `Last-Event-ID` it sends. `Sleep.until!`
## keeps the interval from drifting by the time sending takes.
ticks : RouteContext({}) -> Try(Reply, Reply)
ticks = |context| {
	first = match Sse.last_event_id(context.request) {
		Ok(last) =>
			match U64.from_str(last) {
				Ok(number) => number + 1
				Err(_) => 0
			}
		Err(_) => 0
	}
	Ok(
		Sse.reply_with(
			Sse.Options.{ retry_milliseconds: Sse.Retry.Value(3_000) },
			|sse| send_ticks!(sse, first, Instant.now!({})),
		),
	)
}

send_ticks! : Sse.Writer, U64, Instant => Try({}, [StreamClosed])
send_ticks! = |sse, number, at| {
	tick = Sse.event("tick ${number.to_str()}")
	tick_with_id = match Sse.with_id(tick, number.to_str()) {
		Ok(with_id) => with_id
		Err(InvalidId) => tick
	}
	Sse.send!(sse, tick_with_id)?
	next = at.add_milliseconds(100)
	Sleep.until!(next)
	send_ticks!(sse, number + 1, next)
}

## One event, then a quiet minute: the keep-alive comments go out meanwhile.
quiet : RouteContext({}) -> Try(Reply, Reply)
quiet = |_context|
	Ok(
		Sse.reply_with(
			Sse.Options.{ keep_alive: Sse.KeepAlive.Every(200) },
			|sse| {
				Sse.send!(sse, Sse.event("quiet"))?
				Sleep.millis!(60_000)
				Sse.send!(sse, Sse.event("never"))
			},
		),
	)

events : RouteContext({}) -> Try(Reply, Reply)
events = |_context| {
	second = Sse.event("second\nline")
		|> Sse.with_retry(1000)
	Ok(
		Sse.from_events([
			Sse.event("first"),
			second,
		]),
	)
}

# The query selects the encoded-size boundaries without embedding giant literals.
large_event = |context| {
	seed = if Str.from_utf8_lossy(context.request.query) == "lines" {
		"\n"
	} else {
		"x"
	}
	large = double_text(seed, 16)
	length = match Str.from_utf8_lossy(context.request.query) {
		"below" => 65527
		"at" => 65528
		_ => 65529
	}
	data = Str.from_utf8_lossy(List.sublist(large.to_utf8(), { start: 0, len: length }))
	Ok(Sse.from_events([Sse.event(data), Sse.event("after")]))
}

double_text : Str, U64 -> Str
double_text = |text, remaining| if remaining == 0 {
	text
} else {
	double_text(text.concat(text), remaining - 1)
}
