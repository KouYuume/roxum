app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc", service: "generated/main.roc", wire: "../../libraries/roc-protobuf/package/main.roc" }
import pf.Config
import pf.IpAddr
import pf.Router
import pf.Server
import pf.Sleep
import pf.RateCounter
import service.ExchangeService
import service.UploadsService
import grpc.GrpcClientStream
import grpc.GrpcStatus
import service.UpdatesService
import service.Request
import service.Update
import grpc.GrpcServerStream
import grpc.GrpcMetadata
import grpc.GrpcUnary
import wire.ProtobufWire

Model := { progress : RateCounter }

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| {
	settings : { path : Str }
	settings = Config.load!("path = \"\"").map_err(|ConfigErr(message)| StartupErr(message))?
	progress = RateCounter.new!({ window_seconds: 3600, max_keys: 1 }).map_err(|_| StartupErr("counter unavailable"))?
	Ok({
		model: Model.{ progress },
		listen: {
			endpoint: if Str.is_empty(settings.path) {
				Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 })
			} else {
				Server.Endpoint.Unix({ path: settings.path })
			},
			protocol: Server.Protocol.Http2,
			threads: Server.Threads.Fixed(2),
			timeouts: { ..Server.Timeouts.defaults, response_write_milliseconds: 30_000 },
			drain_timeout_milliseconds: 2000,
			limits: { maximum_requests_in_progress: Server.Count.Fixed(2), maximum_body_bytes: 4096, request_memory: Server.MemoryLimit.Bytes(8 * 1024 * 1024), maximum_streams: Server.Count.Fixed(1) },
		},
	})
}

input_limits = { ..GrpcServerStream.defaults, messages: 4096, request_bytes: 32768, payload_bytes: 64 * 1024 * 1024 }

routes = ExchangeService.register(
	UploadsService.register(updates, { call_submit!: submit! }, input_limits, ProtobufWire.default_limits),
	{ duplex_chat: chat },
	input_limits,
	ProtobufWire.default_limits,
)

submit! = |Model.(model), _metadata| Ok(
	GrpcClientStream.consume(
		0.U32,
		|count, request| consume!(model.progress, count, request),
		|count| Ok(GrpcUnary.response(Update.{ sequence: count, text: "total" })),
	),
)

chat = {
	begin!: |Model.(model), _metadata| Ok({ state: { progress: model.progress, count: 0.U32, large: Bool.False, reply: Bool.False, ended: Bool.False }, initial: [] }),
	receive!: |state, input| match input {
		End => Ok({ ..state, ended: Bool.True })
		Message(request) => {
			count = consume!(state.progress, state.count, request)?
			Request.(fields) = request
			Ok({ ..state, count, large: fields.mode == "large", reply: state.reply or fields.mode == "" or fields.mode == "large" or checkpoint(count) })
		}
	},
	next!: |state| if state.reply {
		Ok(
			Send(
				Update.{
					sequence: state.count,
					text: if state.large {
						Str.repeat("y", 65536)
					} else {
						"ack"
					},
				},
				{ ..state, reply: Bool.False },
			),
		)
	} else if state.ended {
		Ok(Finish([]))
	} else {
		Ok(Read)
	},
}

checkpoint = |count| count == 256 or count == 1024 or count == 2048

consume! = |progress, count, Request.(request)| {
	if request.count != count + 1 {
		return Err(GrpcUnary.failure(GrpcStatus.Code.InvalidArgument, "unexpected sequence"))
	}
	if checkpoint(request.count) or request.mode == "marker" {
		_ = RateCounter.add!(progress, "checkpoint", 1).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.Internal, "counter unavailable"))?
	}
	Ok(request.count)
}

updates = UpdatesService.register(
	Router.new,
	{ call_echo!: echo!, call_watch!: watch! },
	{
		unary: { request_bytes: 1024, response_bytes: 1024, status_bytes: 128, metadata: GrpcMetadata.defaults },
		streaming: { ..GrpcServerStream.defaults, response_bytes: 8192, messages: 32768, payload_bytes: 256 * 1024 * 1024, duration_nanoseconds: 120_000_000_000 },
	},
	ProtobufWire.default_limits,
)

echo! = |Model.(model), Request.(request), _metadata| {
	if request.mode == "progress" {
		counts = RateCounter.counts!(model.progress, "checkpoint")
		return Ok(GrpcUnary.response(Update.{ sequence: (counts.current + counts.previous).to_u32_wrap(), text: "progress" }))
	}
	Ok(GrpcUnary.response(Update.{ sequence: request.count, text: "echo" }))
}

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
