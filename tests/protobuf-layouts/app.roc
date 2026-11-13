app [program] { layouts: "layouts/main.roc", pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.IpAddr
import pf.MethodRouter
import pf.Reply
import pf.RequestBody
import pf.Router
import pf.Server
import layouts.Graph
import layouts.Leaf
import layouts.Observe

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		threads: Server.Threads.Fixed(1),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = Router.new.route("/node", MethodRouter.post(Handler.stateful(answer))).route("/mutual", MethodRouter.post(Handler.stateful(answer))).route("/tree", MethodRouter.post(Handler.stateful(answer)))

# Bound construction before allocating recursive values; this is not a wire decoder.
answer = |_model, context| {
	input = match context.request.body {
		RequestBody.Bytes(bytes) => bytes
		_ => []
	}
	if input.len() != 2 {
		return Ok(Reply.text("InputLength").with_status(400))
	}
	depth = (input.get(0) ?? 0).to_u64()
	seed = (input.get(1) ?? 0).to_u64()
	if depth > 64 {
		return Ok(Reply.text("DepthLimit").with_status(400))
	}
	leaf = Leaf.{ text: "recursive payload ${seed.to_str()} 🐦", payload: [seed.to_u8_wrap(), 0, 255] }
	(before, changed, after) = if context.request.path == "/node" {
		original = Graph.node(depth, seed, leaf)
		initial = Observe.node(original)
		Graph.Node.(record) = original
		replacement = Graph.Node.({ ..record, next: Absent })
		# Keep the original live across replacing the child in a shared record.
		(initial, Observe.node(replacement), Observe.node(original))
	} else if context.request.path == "/mutual" {
		original = Graph.left(depth, seed, leaf)
		initial = Observe.left(original)
		Graph.Left.(record) = original
		replacement = Graph.Left.({ ..record, right: Absent })
		(initial, Observe.left(replacement), Observe.left(original))
	} else {
		original = Graph.tree(depth, seed, leaf)
		initial = Observe.tree(original)
		Graph.Tree.(record) = original
		replacement = Graph.Tree.({ ..record, children: [] })
		(initial, Observe.tree(replacement), Observe.tree(original))
	}
	Ok(Reply.text("${render(before)};${render(changed)};${render(after)}"))
}

render : Observe.Stats -> Str
render = |stats| "${stats.nodes.to_str()},${stats.sum.to_str()},${stats.bytes.to_str()}"
