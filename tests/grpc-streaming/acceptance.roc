app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc", service: "generated/main.roc", wire: "../../libraries/roc-protobuf/package/main.roc" }
import pf.Config
import pf.IpAddr
import pf.Router
import pf.Server
import pf.Sleep
import service.UpdatesService
import service.Request
import service.Update
import grpc.GrpcServerStream
import grpc.GrpcMetadata
import grpc.GrpcUnary
import wire.ProtobufWire

Model := {}

program = { init!, routes: Router.build(routes, {}) }

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
			timeouts: { ..Server.Timeouts.defaults, response_write_milliseconds: 30_000 },
			limits: { maximum_body_bytes: 4096, request_memory: Server.MemoryLimit.Bytes(8 * 1024 * 1024), maximum_streams: Server.Count.Fixed(1) },
		},
	})
}

routes = UpdatesService.register(
	Router.new,
	{ call_echo!: echo!, call_watch!: watch! },
	{
		unary: { request_bytes: 1024, response_bytes: 1024, status_bytes: 128, metadata: GrpcMetadata.defaults },
		streaming: { ..GrpcServerStream.defaults, response_bytes: 8192, messages: 32768, payload_bytes: 256 * 1024 * 1024, duration_nanoseconds: 120_000_000_000 },
	},
	ProtobufWire.default_limits,
)

echo! = |_model, Request.(request), _metadata| Ok(GrpcUnary.response(Update.{ sequence: request.count, text: "echo" }))

watch! = |_model, Request.(request), _metadata| Ok(
	GrpcServerStream.response(
		0.U32,
		|index| {
			if index == request.count {
				Ok(Done([]))
			} else {
				if index == 1 and request.mode == "wait" {
					Sleep.millis!(60_000)
				}
				Ok(Next(Update.{ sequence: index, text: Str.repeat("x", 4096) }, index + 1))
			}
		},
	),
)
