app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc", service: "generated/main.roc", wire: "../../libraries/roc-protobuf/package/main.roc" }
import pf.Config
import pf.IpAddr
import pf.Router
import pf.Server
import pf.RateCounter
import pf.Sleep
import grpc.GrpcClientStream
import service.UploadsService
import service.UpdatesService
import service.Request
import service.Update
import grpc.GrpcServerStream
import grpc.GrpcUnary
import grpc.GrpcMetadata
import grpc.GrpcStatus
import wire.ProtobufWire
Model := { gate : RateCounter }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { path : Str }
	settings = Config.load!("path = \"\"").map_err(|ConfigErr(message)| StartupErr(message))?
	gate = RateCounter.new!({ window_seconds: 3600, max_keys: 1 }).map_err(|_| StartupErr("gate unavailable"))?
	Ok({
		model: Model.{ gate },
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

routes = UploadsService.register(base_routes, { call_submit!: submit! }, { ..GrpcServerStream.defaults, messages: 4, request_bytes: 32, payload_bytes: 40 }, ProtobufWire.default_limits)

submit! = |_model, _metadata| Ok(
	GrpcClientStream.consume(
		0.U32,
		|sum, Request.(request)| {
			if request.mode == "reject" {
				return Err(GrpcUnary.failure(GrpcStatus.Code.PermissionDenied, "denied"))
			}
			if request.count > 4_294_967_295.U32 - sum {
				return Err(GrpcUnary.failure(GrpcStatus.Code.OutOfRange, "total exceeds uint32"))
			}
			Ok(sum + request.count)
		},
		|sum| Ok(GrpcUnary.response(Update.{ sequence: sum, text: "total" })),
	),
)

base_routes = UpdatesService.register(
	Router.new,
	{ call_echo!: echo!, call_watch!: watch! },
	{
		unary: { request_bytes: 1024, response_bytes: 1024, status_bytes: 128, metadata: GrpcMetadata.defaults },
		streaming: { ..GrpcServerStream.defaults, request_bytes: 1024, response_bytes: 64, messages: 4, payload_bytes: 64, duration_nanoseconds: 2000000000 },
	},
	ProtobufWire.default_limits,
)

echo! = |Model.(model), Request.(request), _metadata| {
	if request.mode == "release" {
		_ = RateCounter.add!(model.gate, "release", 1).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.Internal, "gate full"))?
	}
	Ok(GrpcUnary.response(Update.{ sequence: request.count, text: "echo" }))
}

watch! = |Model.(model), Request.(request), _metadata| {
	if request.mode == "reject" {
		return Err(GrpcUnary.failure(GrpcStatus.Code.PermissionDenied, "denied"))
	}
	GrpcServerStream.Response.(response) = GrpcServerStream.response(
		{ index: 0.U32, request },
		|state| {
			if state.index == state.request.count {
				return Ok(
					Done([
						GrpcMetadata.Entry.Text(
							if state.request.mode == "bad-trailing" {
								"authorization"
							} else {
								"done"
							},
							"yes",
						),
					]),
				)
			}
			if state.index == 1 and state.request.mode == "error" {
				return Err(GrpcUnary.failure(GrpcStatus.Code.Aborted, "stopped"))
			}
			if state.index == 1 and state.request.mode == "invalid-status" {
				return Err(GrpcUnary.failure(GrpcStatus.Code.Ok, "bad"))
			}
			if state.index == 1 and state.request.mode == "gated" {
				var $released = Bool.False
				while !$released {
					counts = RateCounter.counts!(model.gate, "release")
					$released = counts.current > 0 or counts.previous > 0
					if !$released {
						Sleep.millis!(1)
					}
				}
			}
			if state.index == 1 and state.request.mode == "deadline" {
				Sleep.millis!(60_000)
			}
			length = match state.request.mode {
				"encoded-below" => 61.U64
				"encoded-exact" => 62
				"encoded-above" => 63
				"oversized" => 65
				"payload" => 30
				"payload-below" => if state.index == 0 {
					28
				} else {
					29
				}
				"payload-exact" => 29
				"payload-above" => if state.index == 0 {
					30
				} else {
					29
				}
				_ => 0
			}
			text = if length == 0 {
				"item"
			} else {
				Str.repeat("x", length)
			}
			Ok(Next(Update.{ sequence: state.index, text }, { ..state, index: state.index + 1 }))
		},
	)
	Ok(
		GrpcServerStream.Response.{
			..response,
			initial: [
				GrpcMetadata.Entry.Text(
					if request.mode == "bad-initial" {
						"grpc-status"
					} else {
						"source"
					},
					"stream",
				),
			],
		},
	)
}
