import pf.HeaderName
import pf.HeaderValue
import pf.Middleware
import pf.Reply
import pf.ResponseHeader

SetHeader := [].{
	## Appends `name: value` to every reply, after the headers the handler set.
	## A header the handler already set is kept, so the response may carry two.
	layer : HeaderName, HeaderValue -> List(Middleware.Stage(model, tag, provided))
	layer = |name, value| {
		header = ResponseHeader.{ name, value }
		[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.with_headers(reply, [header]))]
	}

	## Sets `name: value` on every reply, replacing any header of the same name
	## (compared without regard to case) the handler set, so the response has
	## exactly one.
	replace : HeaderName, HeaderValue -> List(Middleware.Stage(model, tag, provided))
	replace = |name, value| {
		header = ResponseHeader.{ name, value }
		[Middleware.Stage.AfterHandler(|_model, _head, reply| Reply.replace_headers(reply, [header]))]
	}
}
