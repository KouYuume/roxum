app [program] { grpc: "../package/main.roc", pf: platform "../../../platform/main.roc", service: "generated/main.roc", wire: "../../../libraries/roc-protobuf/package/main.roc" }

import pf.IpAddr
import pf.Log
import pf.Router
import pf.Server
import service.GreeterService
import service.Greeting
import service.ReplyText
import wire.ProtobufWire
import grpc.GrpcServerStream
import grpc.GrpcUnary
import grpc.GrpcMetadata
import grpc.GrpcStatus

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		protocol: Server.Protocol.Http2,
		threads: Server.Threads.Fixed(2),
		timeouts: Server.Timeouts.defaults,
		limits: { maximum_body_bytes: 4096 },
	},
})

routes = GreeterService.register(Router.new, { call_greet!: greet!, call_watch!: watch! }, { unary: { request_bytes: 1024, response_bytes: 1024, status_bytes: 128, metadata: GrpcMetadata.defaults }, streaming: GrpcServerStream.defaults }, ProtobufWire.default_limits)

greet! = |_model, Greeting.(input), metadata| {
	Log.info!("Greeting RPC received")
	if Str.is_empty(input.name) {
		return Err(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "name is required"))
	}
	Ok(
		GrpcUnary.Response.{
			message: ReplyText.{ greeting: "Hello ${input.name}" },
			initial: [GrpcMetadata.Entry.Text("service", "greeter")],
			trailing: List.keep_if(
				metadata,
				|entry| match entry {
					GrpcMetadata.Entry.Binary(name, _) => name == "request-bin"
					_ => Bool.False
				},
			),
		},
	)
}

watch! = |_model, Greeting.(input), _metadata| {
	if Str.is_empty(input.name) {
		return Err(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "name is required"))
	}
	Ok(
		GrpcServerStream.response(
			0.U32,
			|index| {
				if index == 3 {
					Ok(Done([]))
				} else {
					Ok(Next(ReplyText.{ greeting: "Hello ${input.name} ${index.to_str()}" }, index + 1))
				}
			},
		),
	)
}
