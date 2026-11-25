app [program] { pf: platform "../../platform/main.roc" }

import pf.Config
import pf.Extract
import pf.ResponseWriter
import pf.RouteContext
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = {
	init!,
	routes: Router.build(routes, {}),
}

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : { tls : Bool, chain : Str, key : Str, unix : Bool, socket_path : Str, timeout : U64, pending : U32, defaults : Bool, short_drain : Bool }
	settings = Config.load!("").map_err(|ConfigErr(msg)| StartupErr(msg))?
	Ok({
		model: {},
		listen: {
			endpoint: if settings.unix {
				Server.Endpoint.Unix({ path: settings.socket_path })
			} else {
				Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 })
			},
			protocol: if settings.tls {
				if settings.defaults {
					options : Server.Tls
					options = { certificate_chain_path: settings.chain, private_key_path: settings.key }
					if options.handshake_timeout_milliseconds != 5_000 or options.maximum_pending_handshakes != 64 {
						return Err(StartupErr("unexpected TLS defaults"))
					}
					Server.Protocol.Tls(options)
				} else {
					Server.Protocol.Tls({ certificate_chain_path: settings.chain, private_key_path: settings.key, handshake_timeout_milliseconds: settings.timeout, maximum_pending_handshakes: settings.pending })
				}
			} else {
				Server.Protocol.Http1
			},
			timeouts: Server.Timeouts.defaults,
			limits: if settings.short_drain {
				Server.Limits.{ maximum_connections: Server.Count.Fixed(1) }
			} else {
				Server.Limits.defaults
			},
			drain_timeout_milliseconds: if settings.short_drain { 500 } else { 20_000 },
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, Roc!\n"))))
	.route("/echo", MethodRouter.post(Handler.effectful(echo!)))
	.route("/stream", MethodRouter.get(Handler.static(|{}| Reply.stream(|writer| ResponseWriter.write!(writer, "streamed".to_utf8())))))

echo! : Model, RouteContext({}) => Try(Reply, Reply)
echo! = |_model, context| {
	bytes = Extract.run!(Extract.bytes, context)?
	Ok(Reply.bytes(bytes, "application/octet-stream"))
}
