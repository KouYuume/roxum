app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc", service: "generated/main.roc", wire: "../../libraries/roc-protobuf/package/main.roc" }

import pf.Config
import pf.IpAddr
import pf.Router
import pf.Server
import service.GreeterService
import service.Greeting
import service.ReplyText
import wire.ProtobufWire
import grpc.GrpcUnary
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

routes = GreeterService.register(Router.new, { call_greet!: greet! }, { request_bytes: 64, response_bytes: 64, status_bytes: 128, metadata: GrpcMetadata.defaults }, ProtobufWire.default_limits)

greet! = |_model, Greeting.(input), metadata| {
	if input.name == "error" {
		return Err(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, " bad name "))
	}
	if input.name == "overflow" {
		return Ok(GrpcUnary.response(ReplyText.{ greeting: Str.from_utf8(List.repeat(97, 65)) ?? "" }))
	}
	if input.name == "invalid-status" {
		return Err(GrpcUnary.failure(GrpcStatus.Code.Ok, "invalid"))
	}
	if input.name == "invalid-metadata" {
		return Ok(GrpcUnary.Response.{ message: ReplyText.{ greeting: "" }, initial: [GrpcMetadata.Entry.Text("connection", "close")], trailing: [] })
	}
	Ok(GrpcUnary.Response.{ message: ReplyText.{ greeting: "Hello ${input.name}" }, initial: [], trailing: metadata })
}
