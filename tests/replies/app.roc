app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.JsonLines
import pf.MediaType
import pf.MethodRouter
import pf.Path
import pf.Redirect
import pf.Reply
import pf.ResponseWriter
import pf.Router
import pf.IpAddr
import pf.Server

## M24 phase 5: helpers for replies, and links built from a route's pattern.
Model := {}

Item := { name : Str, count : U64 }.{
	encoder_for : _
}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| Ok({ model: {}, listen: { endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }), timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })

article = Path.new("/articles/{id}")

route = |path, reply| MethodRouter.get(Handler.static(|{}| reply(path)))

or_500 = |result|
	match result {
		Ok(reply) => reply
		Err(_) => Reply.status(500)
	}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/pdf", route({}, |_| Reply.bytes("%PDF".to_utf8(), "application/pdf")))
		.route("/typed", route({}, |_| Reply.bytes([1], "text/csv; charset=utf-8")))
		.route("/computed", route("image/png", |text| or_500(typed(text))))
		.route("/computed-bad", route("not a type", |text| or_500(typed(text))))
		.route("/see-other", route("/done", |to| or_500(Redirect.see_other(to))))
		.route("/temporary", route("/done", |to| or_500(Redirect.temporary(to))))
		.route("/permanent", route("https://example.com/a?b=c", |to| or_500(Redirect.permanent(to))))
		.route("/bad-location", route("/\u(1F)", |to| or_500(Redirect.see_other(to))))
		.route("/attachment", route("report.csv", |name| or_500(Reply.attachment(Reply.text("a,b"), name))))
		.route("/attachment-unicode", route("山田 \"x\".csv", |name| or_500(Reply.attachment(Reply.bytes("x".to_utf8(), "text/csv"), name))))
		.route("/attachment-stream", route("big.bin", |name| or_500(Reply.attachment(Reply.stream(|writer| ResponseWriter.write!(writer, "x".to_utf8())), name))))
		.route("/attachment-bad", route("../secret", |name| or_500(Reply.attachment(Reply.text("x"), name))))
		.route("/json-record", route({}, |_| Reply.json({ name: "a\"b\ncd", count: 1.U64 })))
		.route("/json-nominal", route({}, |_| Reply.json(Item.{ name: "n", count: 2 })))
		.route("/json-list", route({}, |_| Reply.json([Item.{ name: "x", count: 3 }])))
		.route("/json-empty-list", route(no_items, |items| Reply.json(items)))
		.route("/json-str", route("ok", |text| Reply.json(text)))
		.route("/json-status", route({}, |_| Reply.json({ error: "invalid_item" }).with_status(400)))
		.route("/json-encoded", route("{\"ok\":true}", |text| Reply.bytes(text.to_utf8(), "application/json")))
		.route("/lines-nominal", route({}, |_| Reply.json_lines(|lines| JsonLines.write!(lines, Item.{ name: "l\nm", count: 4 }))))
		.route("/lines", route({}, |_| Reply.json_lines(|lines| write_lines!(lines))))
		.route("/lines-empty", route({}, |_| Reply.json_lines(|_lines| Ok({}))))
		.route(Path.pattern(article), route({}, |_| Reply.text("article")))
		.route("/link-number", route(42.U64, |id| or_500(numbered_link(id))))
		.route(
			"/link/{id}",
			MethodRouter.get(
				Handler.pure(
					|context|
						match List.first(context.path_params) {
							Ok(param) =>
								match Path.url(article, { id: param.value }) {
									Ok(url) => Ok(Reply.text(url))
									Err(_) => Ok(Reply.status(400))
								}
							Err(_) => Ok(Reply.status(500))
						},
				),
			),
		)

numbered_link : U64 -> Try(Reply, [BadLink])
numbered_link = |id|
	match Path.url(article, { id: id }) {
		Ok(url) => Ok(Reply.text(url))
		Err(_) => Err(BadLink)
	}

no_items : List(U64)
no_items = []

typed = |text|
	match MediaType.from_str(text) {
		Ok(media_type) => Ok(Reply.bytes([1], media_type))
		Err(InvalidMediaType) => Err(InvalidMediaType)
	}

write_lines! : JsonLines => Try({}, [StreamClosed])
write_lines! = |lines| {
	ids : List(U64)
	ids = [1, 2]
	for id in ids {
		JsonLines.write!(lines, { id: id })?
	}
	Ok({})
}
