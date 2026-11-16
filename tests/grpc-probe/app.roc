app [program] { pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Handler
import pf.HeaderName
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.ResponseHeader
import pf.Router
import pf.Server
import pf.Version

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { path : Str }
	settings = Config.load!("path = \"\"").map_err(|ConfigErr(message)| StartupErr(message))?
	Ok({
		model: Model.{},
		listen: {
			endpoint: if Str.is_empty(settings.path) { Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }) } else { Server.Endpoint.Unix({ path: settings.path }) },
			protocol: Server.Protocol.Http2,
			threads: Server.Threads.Fixed(2),
			timeouts: Server.Timeouts.defaults,
			limits: { maximum_body_bytes: 1024 },
		},
	})
}

routes : Router(Model, [], {})
routes = {
	handler = MethodRouter.post(Handler.stateful(answer))
	Router.new
		.route("/probe.Echo/Say", handler)
		.route("/probe.Echo/Empty", handler)
		.route("/probe.Echo/Reject", handler)
		.route("/probe.Echo/MissingStatus", handler)
		.route("/probe.Echo/BadLength", handler)
}

# Fixed wire fixtures, not a Protobuf codec or a gRPC integration.
answer = |_model, context| {
	request = context.request
	content_type = List.any(request.headers, |field| field.name == HeaderName.("content-type") and field.value == "application/grpc".to_utf8())
	te = List.any(request.headers, |field| field.name == HeaderName.("te") and field.value == "trailers".to_utf8())
	if request.version != Version.Http20 or !content_type or !te { return Err(Reply.text("invalid gRPC metadata").with_status(415)) }
	body = match request.body {
		RequestBody.Bytes(bytes) => bytes
		_ => []
	}
	# One uncompressed message: field 1 (string), "hello".
	expected = if request.path == "/probe.Echo/Empty" { [0, 0, 0, 0, 0] } else { [0, 0, 0, 0, 7, 10, 5, 104, 101, 108, 108, 111] }
	if body != expected or request.path == "/probe.Echo/Reject" {
		return Ok(Reply.bytes([], "application/grpc").with_trailers([
			ResponseHeader.{ name: HeaderName.("grpc-status"), value: "3" },
			ResponseHeader.{ name: HeaderName.("grpc-message"), value: "fixed%20rejection" },
		]))
	}
	# One uncompressed message: field 1 (string), "world".
	response = if request.path == "/probe.Echo/Empty" { [0, 0, 0, 0, 0] } else if request.path == "/probe.Echo/BadLength" { [0, 0, 0, 0, 8, 10, 5, 119, 111, 114, 108, 100] } else { [0, 0, 0, 0, 7, 10, 5, 119, 111, 114, 108, 100] }
	reply = Reply.bytes(response, "application/grpc")
	if request.path == "/probe.Echo/MissingStatus" { return Ok(reply) }
	Ok(reply.with_trailers([
		ResponseHeader.{ name: HeaderName.("grpc-status"), value: "0" },
		ResponseHeader.{ name: HeaderName.("probe-result"), value: "complete" },
	]))
}
