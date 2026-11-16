app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Router
import pf.Server
import grpc.GrpcWire
import grpc.GrpcFrame
import grpc.GrpcMetadata
import grpc.GrpcStatus

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { path : Str }
	settings = Config.load!("path = \"\"").map_err(|ConfigErr(message)| StartupErr(message))?
	Ok({
		model: Model.{},
		listen: {
			endpoint: if Str.is_empty(settings.path) {
				Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 })
			} else {
				Server.Endpoint.Unix({ path: settings.path })
			},
			protocol: Server.Protocol.Http2,
			threads: Server.Threads.Fixed(2),
			timeouts: Server.Timeouts.defaults,
			limits: { maximum_body_bytes: 4096 },
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new.route("/wire.Test/Echo", MethodRouter.post(Handler.stateful(answer))).route("/wire.Test/Failure", MethodRouter.post(Handler.stateful(answer)))

answer = |_model, context| {
	request = context.request
	metadata = match GrpcWire.request_metadata(request.version, request.method, request.headers, GrpcMetadata.defaults) {
		Ok(value) => value
		Err(error) => return Ok(GrpcWire.reject_request(error))
	}
	bytes = match request.body {
		RequestBody.Bytes(value) => value
		_ => []
	}
	message = match GrpcFrame.decode_unary(bytes, 64) {
		Ok(value) => value
		Err(error) => return Ok(GrpcWire.reject_frame(error))
	}
	if request.path == "/wire.Test/Failure" {
		return Ok(GrpcWire.failure(GrpcStatus.Code.InvalidArgument, " é %\n ", metadata, { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.text("response failure").with_status(500))
	}
	Ok(
		GrpcWire.success(
			message,
			[GrpcMetadata.Entry.Text("wire-test", " initial ")],
			metadata.map(
				|entry| match entry {
					GrpcMetadata.Entry.Text(name, text) => GrpcMetadata.Entry.Text(name, " ${text} ")
					GrpcMetadata.Entry.Binary(_, _) => entry
				},
			),
			{ message_bytes: 64, metadata: GrpcMetadata.defaults },
		) ?? Reply.text("response failure").with_status(500),
	)
}
