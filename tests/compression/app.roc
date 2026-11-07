app [program] { pf: platform "../../platform/main.roc" }

import pf.Compression
import pf.FileRoot
import pf.Files
import pf.Handler
import pf.HeaderName
import pf.HeaderValue
import pf.HttpError
import pf.MethodRouter
import pf.Reply
import pf.ResponseHeader
import pf.ResponseWriter
import pf.Router
import pf.Server
import pf.Sleep

## Responses with and without `Compression.layer`: bodies in memory
##, bodies written as they go, and files. The test prepares
## `public/` in the working directory.
Model := { public : FileRoot }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	public = match Files.open_root!("public") {
		Ok(root) => root
		Err(_) => return Err(StartupErr("public cannot be opened"))
	}
	Ok({
		model: { public },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

compressed : Handler(Model, [], {}) -> MethodRouter(Model, [], {})
compressed = |handler| MethodRouter.get(handler).layer(Compression.layer(Compression.Options.{}))

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/json", compressed(Handler.static(|{}| Reply.bytes(json.to_utf8(), "application/json"))))
		.route("/large", compressed(Handler.static(|{}| Reply.text(repeat("roxum compresses this line. ", 16)))))
		.route("/small", compressed(Handler.static(|{}| Reply.text("short"))))
		.route("/image", compressed(Handler.static(|{}| Reply.bytes(json.to_utf8(), "image/png"))))
		.route("/svg", compressed(Handler.static(|{}| Reply.text(json).replace_headers([header("content-type", "image/svg+xml")]))))
		.route("/encoded", compressed(Handler.static(|{}| Reply.text(json).with_headers([header("content-encoding", "br")]))))
		.route("/error", compressed(Handler.pure(|_context| Err(Reply.error(HttpError.bad_request(json))))))
		.route(
			"/narrow",
			MethodRouter.get(Handler.static(|{}| Reply.text(json)))
				.layer(Compression.layer(Compression.Options.{ above_bytes: 100_000 })),
		)
		.route("/plain", MethodRouter.get(Handler.static(|{}| Reply.text(json))))
		.route("/stream", compressed(Handler.static(|{}| Reply.stream(|writer| write_parts!(writer, 1)) |> typed("text/plain"))))
		.route("/events", compressed(Handler.static(|{}| Reply.stream(|writer| write_parts!(writer, 1)) |> typed("text/event-stream"))))
		.route("/beats", compressed(Handler.static(|{}| Reply.stream_with(beating, |writer| write_and_wait!(writer)) |> typed("text/plain"))))
		.route("/file/{*path}", compressed(Files.serve(|model| model.public)))

## Three parts 300 ms apart.
write_parts! : ResponseWriter, U64 => Try({}, [StreamClosed])
write_parts! = |writer, number|
	if number > 3 {
		Ok({})
	} else {
		ResponseWriter.write!(writer, "part ${number.to_str()} ${repeat("of a stream that compresses well. ", 8)}\n".to_utf8())?
		Sleep.millis!(300)
		write_parts!(writer, number + 1)
	}

beating : ResponseWriter.Options
beating = ResponseWriter.Options.{
	keep_alive: ResponseWriter.KeepAlive.Every({ milliseconds: 100, bytes: "beat\n".to_utf8() }),
	ends_on_drain: Bool.True,
}

## One part, then quiet until the server drains.
write_and_wait! : ResponseWriter => Try({}, [StreamClosed])
write_and_wait! = |writer| {
	ResponseWriter.write!(writer, "first\n".to_utf8())?
	Sleep.millis!(60_000)
	ResponseWriter.write!(writer, "never\n".to_utf8())
}

json : Str
json = "{\"items\":[${repeat("{\"name\":\"roxum\",\"kind\":\"server\"},", 200)}{}]}"

repeat : Str, U64 -> Str
repeat = |text, count| if count == 0 { "" } else { text.concat(repeat(text, count - 1)) }

header : Str, Str -> ResponseHeader
header = |name, text| {
	value : HeaderValue
	value = match HeaderValue.from_str(text) {
		Ok(valid) => valid
		Err(_) => "invalid"
	}
	ResponseHeader.{ name: HeaderName.(name), value }
}

typed : Reply, Str -> Reply
typed = |reply, media| reply.with_headers([header("content-type", media)])
