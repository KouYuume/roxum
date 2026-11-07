app [program] { pf: platform "../../platform/main.roc" }

import "config/base.toml" as base_text : Str
import pf.Config
import pf.Handler
import pf.Instant
import pf.MethodRouter
import pf.Reply
import pf.Response
import pf.ResponseBody
import pf.ResponseWriter
import pf.RouteContext
import pf.Router
import pf.Server
import pf.Tcp

## One worker with the access log mode and the queue timeout from the
## settings. Its routes answer in each way an access log line tells apart:
## a matched route, a nested one, an error reply, a stream, a crash, and the
## custom fallback. `/busy/{milliseconds}` keeps the Roc thread computing,
## so a request queued behind it waits past the queue timeout.
## `/wait/{milliseconds}` asks the test's delay server through a pool, as an
## outbound call does.
Settings : {
	access_log : Str,
	queue_timeout_milliseconds : U64,
	metrics_port : U64,
	delay_port : U16,
}

Model := { delay : Tcp.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	access_log =
		if settings.access_log == "json_lines" {
			Server.AccessLog.JsonLines
		} else if settings.access_log == "json_lines_with_path" {
			Server.AccessLog.JsonLinesWithPath
		} else {
			Server.AccessLog.Off
		}
	metrics =
		if settings.metrics_port == 0 {
			Server.Metrics.Off
		} else {
			Server.Metrics.Listen({ address: Server.Ipv4Address.(127, 0, 0, 1), port: U64.to_u16_wrap(settings.metrics_port) })
		}
	delay = Tcp.pool!(Tcp.PoolOptions.{ host: "127.0.0.1", port: settings.delay_port, maximum_connections: 4 }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { delay },
		listen: Server.ListenOptions.{
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.{
				queue_timeout_milliseconds: settings.queue_timeout_milliseconds,
			},
			threads: Server.Threads.Fixed(1),
			access_log,
			metrics,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/users/{id}", MethodRouter.get(Handler.static(|{}| Reply.text("user\n"))))
		.nest("/api/{tenant}", Router.new.route("/items/{id}", MethodRouter.get(Handler.static(|{}| Reply.text("item\n")))))
		.route("/teapot", MethodRouter.get(Handler.pure(teapot)))
		.route("/stream", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| write_chunks!(writer, 2)))))
		.route("/crash", MethodRouter.get(Handler.pure(crash_reply)))
		.route("/busy/{milliseconds}", MethodRouter.get(Handler.effectful(busy!)))
		.route("/wait/{milliseconds}", MethodRouter.get(Handler.effectful(wait!)))
		.fallback(
			|reason, _model, _head|
				match reason {
					Router.Unmatched.NotFound => Ok(Reply.text("fallback\n").with_status(404))
					Router.Unmatched.MethodNotAllowed(_) => Ok(Reply.status(405))
					Router.Unmatched.BadPath => Ok(Reply.status(400))
				},
		)

teapot : RouteContext({}) -> Try(Reply, Reply)
teapot = |_context| Err(Reply.text("teapot\n").with_status(418))

crash_reply : RouteContext({}) -> Try(Reply, Reply)
crash_reply = |_context| crash "observability test crash"

## `remaining` chunks of `abc`.
write_chunks! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_chunks! = |writer, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, "abc".to_utf8())?
		write_chunks!(writer, remaining - 1)
	}

milliseconds_of : RouteContext({}) -> U64
milliseconds_of = |context|
	match List.first(context.path_params) {
		Ok(param) => U64.from_str(param.value) ?? 0
		Err(_) => 0
	}

## Asks the delay server to answer after `milliseconds`.
wait! : Model, RouteContext({}) => Try(Reply, Reply)
wait! = |model, context| {
	answer = Tcp.with!(
		model.delay,
		|connection| {
			Tcp.write!(connection, "${milliseconds_of(context).to_str()}\n".to_utf8(), 60_000)?
			Tcp.read!(connection, 64, 60_000)
		},
	)
	match answer {
		Ok(_) => Ok(Reply.text("waited\n"))
		Err(_) => Ok(Reply.text("failed\n"))
	}
}

## Computes until `milliseconds` have passed, holding the Roc thread.
busy! : Model, RouteContext({}) => Try(Reply, Reply)
busy! = |_model, context| {
	milliseconds = milliseconds_of(context)
	started = Instant.now!({})
	var $spins = 0
	while Instant.nanoseconds_between(started, Instant.now!({})) < milliseconds * 1_000_000 {
		$spins = $spins + 1
	}
	Ok(Reply.text("busy\n"))
}
