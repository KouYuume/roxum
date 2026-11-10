app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.Instant
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import pf.Sleep
import pf.Tcp

## One process with the admission limits and threads from the settings.
## `/busy/{ms}` keeps a Roc thread computing, so with one thread requests
## queue behind it; `/wait/{ms}` waits for a delay server the test runs, on
## a fiber, as an outbound call does. `/sleep/{ms}` and `/ticks/{ms}` wait
## with `Sleep`.
Settings : {
	delay_port : U16,
	threads : U16,
	maximum_queued_requests : U64,
	queue_timeout_milliseconds : U64,
	maximum_requests_in_progress : U64,
	maximum_connections : U64,
	request_memory_bytes : U64,
}

Model := { delay : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	# Off a fiber the thread waits.
	Sleep.millis!(1)
	delay = Tcp.pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.delay_port, maximum_connections: 64 }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { delay },
		listen: Server.ListenOptions.{
			address: IpAddr.V4((127, 0, 0, 1)),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.{
				maximum_queued_requests: Server.Count.Fixed(settings.maximum_queued_requests),
				queue_timeout_milliseconds: settings.queue_timeout_milliseconds,
				maximum_requests_in_progress: Server.Count.Fixed(settings.maximum_requests_in_progress),
				maximum_connections: Server.Count.Fixed(settings.maximum_connections),
				request_memory: if settings.request_memory_bytes == 0 {
					Server.MemoryLimit.Auto
				} else {
					Server.MemoryLimit.Bytes(settings.request_memory_bytes)
				},
			},
			threads: Server.Threads.Fixed(settings.threads),
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/fast", MethodRouter.get(Handler.static(|{}| Reply.text("fast\n"))))
		.route("/busy/{milliseconds}", MethodRouter.get(Handler.effectful(busy!)))
		.route("/wait/{milliseconds}", MethodRouter.get(Handler.effectful(wait!)))
		.route("/hold/{kibibytes}/{milliseconds}", MethodRouter.get(Handler.effectful(hold!)))
		.route("/sleep/{milliseconds}", MethodRouter.get(Handler.effectful(sleep!)))
		.route("/ticks/{milliseconds}", MethodRouter.get(Handler.effectful(ticks!)))

sleep! : Model, RouteContext({}) => Try(Reply, Reply)
sleep! = |_model, context| {
	Sleep.millis!(milliseconds_of(context))
	Ok(Reply.text("slept\n"))
}

## Three ticks `milliseconds` apart from the start, with a computation of
## a few milliseconds in each that `Sleep.until!` does not add to the
## interval. Answers the milliseconds the ticks took, and waits once more
## for a deadline already passed.
ticks! : Model, RouteContext({}) => Try(Reply, Reply)
ticks! = |_model, context| {
	interval = milliseconds_of(context)
	started = Instant.now!({})
	var $deadline = started
	var $count = 0
	while $count < 3 {
		spin!(5)
		$deadline = Instant.add_milliseconds($deadline, interval)
		Sleep.until!($deadline)
		$count = $count + 1
	}
	Sleep.until!(started)
	took = Instant.nanoseconds_between(started, Instant.now!({})) // 1_000_000
	Ok(Reply.text("${took.to_str()}\n"))
}

spin! : U64 => {}
spin! = |milliseconds| {
	started = Instant.now!({})
	var $spins = 0
	while Instant.nanoseconds_between(started, Instant.now!({})) < milliseconds * 1_000_000 {
		$spins = $spins + 1
	}
}

milliseconds_of : RouteContext({}) -> U64
milliseconds_of = |context| number_of(context, "milliseconds")

number_of : RouteContext({}), Str -> U64
number_of = |context, name|
	match List.first(List.keep_if(context.path_params, |param| param.name == name)) {
		Ok(param) => U64.from_str(param.value) ?? 0
		Err(_) => 0
	}

## Holds `kibibytes` of values while waiting `milliseconds` for the delay
## server, as a request that builds a large result before an outbound call.
hold! : Model, RouteContext({}) => Try(Reply, Reply)
hold! = |model, context| {
	held : List(U8)
	held = List.repeat('x', number_of(context, "kibibytes") * 1024)
	answer = Tcp.with!(
		model.delay,
		|connection| {
			Tcp.write!(connection, "${milliseconds_of(context).to_str()}\n".to_utf8(), 60_000)?
			Tcp.read!(connection, 64, 60_000)
		},
	)
	match answer {
		Ok(_) => Ok(Reply.text("held ${held.len().to_str()} ${(held.last() ?? 0).to_str()}\n"))
		Err(TcpOverloaded) => Ok(Reply.text("TcpOverloaded\n"))
		Err(_) => Ok(Reply.text("failed\n"))
	}
}

## Computes until `milliseconds` have passed, holding the Roc thread.
busy! : Model, RouteContext({}) => Try(Reply, Reply)
busy! = |_model, context| {
	limit = milliseconds_of(context) * 1_000_000
	started = Instant.now!({})
	var $spins = 0
	while Instant.nanoseconds_between(started, Instant.now!({})) < limit {
		$spins = $spins + 1
	}
	Ok(Reply.text("busy\n"))
}

## Asks the delay server to answer after `milliseconds`.
wait! : Model, RouteContext({}) => Try(Reply, Reply)
wait! = |model, context| {
	milliseconds = milliseconds_of(context)
	answer = Tcp.with!(
		model.delay,
		|connection| {
			Tcp.write!(connection, "${milliseconds.to_str()}\n".to_utf8(), 60_000)?
			Tcp.read!(connection, 64, 60_000)
		},
	)
	match answer {
		Ok(_) => Ok(Reply.text("waited\n"))
		Err(_) => Ok(Reply.text("failed\n"))
	}
}
