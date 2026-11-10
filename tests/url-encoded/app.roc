app [program] { pf: platform "../../platform/main.roc" }

import pf.Extract
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server
import pf.UrlEncoded

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })

routes : Router(Model, [], {})
routes = Router.new
	.route("/decode", MethodRouter.post(handler({ max_bytes: 4096, max_fields: 256 })))
	.route("/bytes", MethodRouter.post(handler({ max_bytes: 3, max_fields: 256 })))
	.route("/fields", MethodRouter.post(handler({ max_bytes: 4096, max_fields: 2 })))
	.route("/zero", MethodRouter.post(handler({ max_bytes: 0, max_fields: 0 })))
	.route("/no-fields", MethodRouter.post(handler({ max_bytes: 4096, max_fields: 0 })))

# This fixture maps errors to text, not a proposed extractor HTTP contract.
handler = |limits| Handler.effectful(
	|_model, context| {
		bytes = Extract.run!(Extract.bytes, context)?
		Ok(
			match UrlEncoded.decode(bytes, limits) {
				Err(TooManyBytes) => Reply.text("bytes")
				Err(TooManyFields) => Reply.text("fields")
				Ok(pairs) => Reply.text(Str.join_with(pairs.map(|pair| "${pair.name.to_utf8().len().to_str()}:${pair.name}${pair.value.to_utf8().len().to_str()}:${pair.value}"), ""))
			},
		)
	},
)
