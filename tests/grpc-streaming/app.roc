app [program] { grpc: "../../integrations/roxum-grpc/package/main.roc", pf: platform "../../platform/main.roc", service: "generated/main.roc", wire: "../../libraries/roc-protobuf/package/main.roc" }
import pf.Config
import pf.IpAddr
import service.ExchangeService
import pf.MethodRouter
import pf.Router
import pf.Server
import pf.RateCounter
import pf.Sleep
import grpc.GrpcDuplex
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
	gate = RateCounter.new!({ window_seconds: 3600, max_keys: 3 }).map_err(|_| StartupErr("gate unavailable"))?
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

duplex_limits = { ..GrpcServerStream.defaults, messages: 8, payload_bytes: 65544 }

heap_uploads = UploadsService.register(Router.new, { call_submit!: submit! }, { ..GrpcServerStream.defaults, request_bytes: 9 * 1024 * 1024 }, ProtobufWire.default_limits)

# A short wire request controls how much memory the pure codec allocates.
expand_request = |bytes| {
	Request.(value) = Request.decode(bytes, ProtobufWire.default_limits)?
	if value.mode == "expand" {
		Ok(Request.{ ..value, mode: Str.repeat("x", value.count.to_u64()) })
	} else {
		Ok(Request.(value))
	}
}

heap_updates : UpdatesService.Handlers(Model)
heap_updates = { call_echo!: echo!, call_watch!: watch! }
heap_submit : UploadsService.Handlers(Model)
heap_submit = { call_submit!: submit! }

heap_routes = heap_uploads
	.route("/chat", MethodRouter.post(GrpcDuplex.handler(expand_request, Update.encode, chat, { ..duplex_limits, request_bytes: 9 * 1024 * 1024, payload_bytes: 9 * 1024 * 1024, status_bytes: 0 })))
	.route("/echo", MethodRouter.post(GrpcUnary.handler(expand_request, Update.encode, heap_updates.call_echo!, { request_bytes: 1024, response_bytes: 1024, status_bytes: 128, metadata: GrpcMetadata.defaults })))
	.route("/watch", MethodRouter.post(GrpcServerStream.handler(expand_request, Update.encode, heap_updates.call_watch!, GrpcServerStream.defaults)))
	.route("/submit", MethodRouter.post(GrpcClientStream.handler(expand_request, Update.encode, heap_submit.call_submit!, GrpcServerStream.defaults)))

routes = ExchangeService.register(uploads, { duplex_chat: chat }, duplex_limits, ProtobufWire.default_limits).nest("/heap", heap_routes)

chat = {
	begin!: |Model.(model), _metadata| Ok({ state: { gate: model.gate, replies: [], count_reads: Bool.False, ended: Bool.False }, initial: [] }),
	receive!: |state, input| match input {
		End => Ok({ ..state, ended: Bool.True })
		Message(Request.(request)) => {
			if request.mode == "finish" {
				return Ok({ ..state, ended: Bool.True })
			}
			if request.mode == "observe" or request.mode == "deny" {
				_ = RateCounter.add!(state.gate, "upload", 1).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.Internal, "gate full"))?
			}
			if request.mode == "deny" {
				return Err(GrpcUnary.failure(GrpcStatus.Code.PermissionDenied, "denied"))
			}
			if request.mode == "burst" and request.count <= 9 {
				return Ok({ ..state, replies: state.replies.concat(List.repeat(Update.{ sequence: 0, text: "" }, request.count.to_u64())) })
			}
			if request.mode == "sized" and request.count <= 32769 {
				return Ok({ ..state, replies: state.replies.append(Update.{ sequence: 0, text: Str.repeat("x", request.count.to_u64()) }) })
			}
			if state.count_reads {
				counts = RateCounter.counts!(state.gate, "reads")
				return Ok({ ..state, replies: state.replies.append(Update.{ sequence: (counts.current + counts.previous).to_u32_wrap(), text: "reads" }), count_reads: Bool.False })
			}
			text = if request.mode == "large" {
				Str.repeat("x", 65536)
			} else {
				"ack"
			}
			Ok({ ..state, replies: state.replies.append(Update.{ sequence: request.count, text }), count_reads: request.mode == "count-reads" })
		}
	},
	next!: |state| match state.replies.first() {
		Ok(message) => Ok(Send(message, { ..state, replies: state.replies.drop_first(1) }))
		Err(_) => if state.ended {
			Ok(Finish([]))
		} else {
			if state.count_reads {
				_ = RateCounter.add!(state.gate, "reads", 1).map_err(|_| GrpcUnary.failure(GrpcStatus.Code.Internal, "gate full"))?
			}
			Ok(Read)
		}
	},
}

uploads = UploadsService.register(base_routes, { call_submit!: submit! }, { ..GrpcServerStream.defaults, messages: 4, request_bytes: 32, payload_bytes: 40 }, ProtobufWire.default_limits)

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
	if request.mode == "observed" {
		counts = RateCounter.counts!(model.gate, "upload")
		return Ok(GrpcUnary.response(Update.{ sequence: (counts.current + counts.previous).to_u32_wrap(), text: "observed" }))
	}
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
