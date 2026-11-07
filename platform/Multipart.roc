import Handler
import HttpError
import Http
import MultipartBody
import Reply
import RequestHead

## A multipart/form-data upload too large to hold, field by field as it arrives
##. A small form reads simpler with `Extract.Multipart`.
##
## - `begin!` runs before the body is received, and returns the state to start from.
## - `field!` runs at the start of each field, with its name, `filename`, and
##   `content_type`. `filename` is what the client wrote: never use it as a path.
## - `chunk!` gets the bytes of the current field in parts, cut anywhere.
## - `done!` runs after the closing delimiter and returns the reply.
## - `abort!`, which may be left out, runs as for `Handler.streaming`.
##
## The Content-Type must be multipart/form-data with a boundary, or the request gets
## 415 before `begin!`. A malformed body gets 400 and a body past `limits` 413.
Multipart :: [].{
	Callbacks(model, state, tag, provided) := {
		begin! : model, RequestHead(tag, provided) => Try(state, Reply),
		field! : state, MultipartBody.FieldHead => Try(state, Reply),
		chunk! : state, List(U8) => Try(state, Reply),
		done! : model, state => Try(Reply, Reply),
		abort! : state, Handler.StreamEnd => {} ?? |_state, _reason| {},
		limits : MultipartBody.Limits ?? MultipartBody.Limits.{},
	}

	## The callbacks for `Handler.streaming`.
	streaming : Multipart.Callbacks(model, state, tag, provided) -> Handler.Streaming(model, { parser : MultipartBody.Parser, inner : state }, tag, provided)
	streaming = |callbacks| Handler.Streaming.{
		begin!: |model, head|
			match boundary_of(head.headers) {
				Err(NotMultipart) => Err(Reply.error(HttpError.make(415, "expected a multipart/form-data Content-Type")))
				Ok(boundary) => {
					inner = (callbacks.begin!)(model, head)?
					Ok({ parser: MultipartBody.new(boundary, callbacks.limits), inner })
				}
			},
		chunk!: |state, bytes|
			match MultipartBody.feed(state.parser, bytes) {
				Err(failure) => Err(failure_reply(failure))
				Ok(fed) => {
					var $inner = state.inner
					for event in fed.events {
						$inner = match event {
							Field(head) => (callbacks.field!)($inner, head)?
							Data(data) => (callbacks.chunk!)($inner, data)?
						}
					}
					Ok({ parser: fed.parser, inner: $inner })
				}
			},
		done!: |model, state|
			match MultipartBody.finish(state.parser) {
				Err(failure) => Err(failure_reply(failure))
				Ok({}) => (callbacks.done!)(model, state.inner)
			},
		abort!: |state, reason| (callbacks.abort!)(state.inner, reason),
	}
}

boundary_of = |headers|
	match List.keep_if(headers, |field| field.name == Http.HeaderName.("content-type")) {
		[field] => MultipartBody.boundary(field.value)
		_ => Err(NotMultipart)
	}

failure_reply = |failure|
	match failure {
		Invalid => Reply.error(HttpError.bad_request("invalid multipart body"))
		TooLarge => Reply.error(HttpError.make(413, "multipart body too large"))
	}
