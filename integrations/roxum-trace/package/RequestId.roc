import pf.HeaderName
import pf.HeaderValue
import pf.Middleware
import pf.Reply
import pf.ResponseHeader

RequestId := [].{
	## Sets the request's ID as the `x-request-id` of both successful and error
	## replies, replacing any the handler added, so a client can quote it. The
	## host decides the ID (`request.request_id`) before any app code runs, as
	## `listen.request_id` says; its logs name the request by the same ID.
	##
	## A function of `{}` because a value cannot be generic over `model`.
	layer : {} -> List(Middleware.Stage(model, tag, provided))
	layer = |{}| [
		Middleware.Stage.AfterHandler(
			|_model, head, reply|
				match HeaderValue.from_str(head.request_id) {
					Ok(value) => Reply.replace_headers(reply, [ResponseHeader.{ name: request_id_name, value }])
					# The host's IDs are visible ASCII; only a request built in
					# Roc code, as in a test, can hold one that is not.
					Err(_) => reply
				},
		),
	]
}

request_id_name : HeaderName
request_id_name = HeaderName.("x-request-id")
