app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.RouteContext
import pf.Router
import pf.IpAddr
import pf.Server
import pf.Sleep
import pf.Tcp

## Requests that are still running when the server is asked to stop: one
## that waits for a delay server the test runs (on a fiber, as an outbound
## call does), one that computes without end, a long stream, and streams
## without end that a drain may end: one waits in a sleep, one for
## the delay server.
Settings : { delay_port : U16, drain_timeout_milliseconds : U64 }

Model := { delay : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	delay = Tcp.pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.delay_port, maximum_connections: 16 }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { delay },
		listen: Server.ListenOptions.{
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
			drain_timeout_milliseconds: settings.drain_timeout_milliseconds,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/fast", MethodRouter.get(Handler.static(|{}| Reply.text("fast\n"))))
		.route("/wait/{milliseconds}", MethodRouter.get(Handler.effectful(wait!)))
		.route("/spin", MethodRouter.get(Handler.static(|{}| Reply.text("${spin(1).to_str()}\n"))))
		.route("/stream", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_chunks!(writer, 256)))))
		.route("/events", MethodRouter.get(Handler.static(|{}| Reply.stream_with(ends_on_drain, write_events!))))
		.route("/events-waiting", MethodRouter.get(Handler.effectful(events_waiting!)))

ends_on_drain : ResponseWriter.Options
ends_on_drain = ResponseWriter.Options.{ ends_on_drain: Bool.True }

## An event every 50 ms, without end.
write_events! : ResponseWriter => Try({}, [StreamClosed])
write_events! = |writer| {
	ResponseWriter.write!(writer, "data: tick\n\n".to_utf8())?
	Sleep.millis!(50)
	write_events!(writer)
}

## An event, then a wait of a minute for the delay server, without end.
events_waiting! : Model, RouteContext({}) => Try(Reply, Reply)
events_waiting! = |model, _context|
	Ok(
		Reply.stream_with(
			ends_on_drain,
			|writer| {
				ResponseWriter.write!(writer, "data: waiting\n\n".to_utf8())?
				_ = Tcp.with!(
					model.delay,
					|connection| {
						Tcp.write!(connection, "60000\n".to_utf8(), 120_000)?
						Tcp.read!(connection, 64, 120_000)
					},
				)
				ResponseWriter.write!(writer, "data: never\n\n".to_utf8())
			},
		),
	)

## Asks the delay server to answer after `milliseconds`.
wait! : Model, RouteContext({}) => Try(Reply, Reply)
wait! = |model, context| {
	milliseconds = match List.first(context.path_params) {
		Ok(param) => param.value
		Err(_) => "0"
	}
	answer = Tcp.with!(
		model.delay,
		|connection| {
			Tcp.write!(connection, "${milliseconds}\n".to_utf8(), 60_000)?
			Tcp.read!(connection, 64, 60_000)
		},
	)
	match answer {
		Ok(_) => Ok(Reply.text("waited\n"))
		Err(_) => Ok(Reply.text("failed\n"))
	}
}

## Never returns: a handler the host cannot interrupt. `n` stays in 1..1000, so
## the call neither ends nor overflows; `--opt=speed` turned `spin(n + 1)` into
## an immediate overflow crash.
spin : U64 -> U64
spin = |n| if n == 0 { 0 } else { spin(n % 1000 + 1) }

## `remaining` chunks of 64 KiB.
write_chunks! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_chunks! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, List.repeat('x', 64 * 1024))?
		write_chunks!(writer, remaining - 1)
	}
