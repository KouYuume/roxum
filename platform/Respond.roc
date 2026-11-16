import HeaderValue
import Http
import HttpError
import MediaType
import Reply
import Status

## Converts `Reply` values into `Http.Response` values. The router calls this
## after each handler; apps rarely need it directly.
Respond :: [].{
	## Builds the response described by `reply`. Wrappers apply from the inside
	## out: `with_status` sets the status, and `with_headers` appends headers.
	to_response : Reply -> Http.Response
	to_response = |reply|
		match reply {
			Text(value) => with_body(value.to_utf8(), "text/plain; charset=utf-8")
			Json(value) => with_body(value.to_utf8(), "application/json")
			Bytes(value, media_type) => {
				header = match HeaderValue.from_str(MediaType.inner(media_type)) {
					Ok(field) => field
					Err(CrlfInjection) => crash "a MediaType holds no line break"
				}
				Http.Response.{
					status: 200,
					headers: [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value: header }],
					body: Http.ResponseBody.Bytes(value),
				}
			}
			Empty => Http.Response.{ status: 200, headers: [], body: Http.ResponseBody.Empty }
			StatusOnly(status) => Http.Response.{ status: Status.code(status), headers: [], body: Http.ResponseBody.Empty }
			WithStatus(status, inner) => { ..Respond.to_response(inner), status: Status.code(status) }
			WithHeaders(headers, inner) => {
				response = Respond.to_response(inner)
				{ ..response, headers: List.concat(response.headers, headers) }
			}
			WithTrailers(trailers, inner) => {
				response = Respond.to_response(inner)
				{ ..response, trailers: List.concat(response.trailers, trailers) }
			}
			ReplaceHeaders(headers, inner) => {
				response = Respond.to_response(inner)
				kept = List.drop_if(response.headers, |existing| List.any(headers, |header| same_name(header, existing)))
				{ ..response, headers: List.concat(kept, headers) }
			}
			Full(response) => response
			Err(error) => error_response(error)
			Routed(_, inner) | Compressible(_, inner) => Respond.to_response(inner)
			# The head of a streamed body; the platform writes the body.
			Writes(_, _) | File(_, _) => Http.Response.{ status: 200, headers: [], body: Http.ResponseBody.Empty }
		}

	## Converts a handler result. `Ok` and `Err` are converted the same way.
	from_result : Try(Reply, Reply) -> Http.Response
	from_result = |result|
		match result {
			Ok(reply) => Respond.to_response(reply)
			Err(reply) => Respond.to_response(reply)
		}
}

with_body = |bytes, content_type| {
	value : HeaderValue
	value = content_type
	Http.Response.{
		status: 200,
		headers: [Http.ResponseHeader.{ name: Http.HeaderName.("content-type"), value }],
		body: Http.ResponseBody.Bytes(bytes),
	}
}

error_response = |error| {
	response = with_body((HttpError.message(error)).to_utf8(), "text/plain; charset=utf-8")
	{ ..response, status: Status.code(HttpError.status(error)) }
}

## Header names compare without regard to ASCII case.
same_name : Http.ResponseHeader, Http.ResponseHeader -> Bool
same_name = |left, right| ascii_lower(Http.HeaderName.inner(left.name)) == ascii_lower(Http.HeaderName.inner(right.name))

ascii_lower : Str -> List(U8)
ascii_lower = |text| List.map(Str.to_utf8(text), |byte| if byte >= 'A' and byte <= 'Z' { byte + 32 } else { byte })

expect {
	response = Respond.to_response(Reply.text("hello"))
	response.status == 200 and match response.body {
		Http.ResponseBody.Bytes(bytes) => bytes == "hello".to_utf8()
		Http.ResponseBody.Empty => Bool.False
	}
}

expect {
	reply = Reply.text("missing").with_status(404)
	response = Respond.to_response(reply)
	response.status == 404 and match response.body {
		Http.ResponseBody.Bytes(bytes) => bytes == "missing".to_utf8()
		Http.ResponseBody.Empty => Bool.False
	}
}

expect {
	reply = Reply.error(HttpError.bad_request("bad input"))
	response = Respond.to_response(reply)
	response.status == 400 and match response.body {
		Http.ResponseBody.Bytes(bytes) => bytes == "bad input".to_utf8()
		Http.ResponseBody.Empty => Bool.False
	}
}

expect {
	response = Respond.to_response(Reply.json({ ok: Bool.True }))
	response.status == 200 and match response.headers {
		[header] => Http.HeaderName.inner(header.name) == "content-type" and header.value == "application/json"
		_ => Bool.False
	} and match response.body {
		Http.ResponseBody.Bytes(bytes) => bytes == "{\"ok\":true}".to_utf8()
		Http.ResponseBody.Empty => Bool.False
	}
}

expect {
	response = Respond.to_response(Reply.bytes([0, 127, 255], "application/octet-stream"))
	List.len(response.headers) == 1 and match response.body {
		Http.ResponseBody.Bytes(bytes) => bytes == [0, 127, 255]
		Http.ResponseBody.Empty => Bool.False
	}
}

expect {
	response = Respond.to_response(Reply.empty)
	response.status == 200 and response.headers == [] and match response.body {
		Http.ResponseBody.Empty => Bool.True
		Http.ResponseBody.Bytes(_) => Bool.False
	}
}

expect {
	inner_value : HeaderValue
	inner_value = "inner"
	outer_value : HeaderValue
	outer_value = "outer"
	inner_header = Http.ResponseHeader.{ name: Http.HeaderName.("x-inner"), value: inner_value }
	outer_header = Http.ResponseHeader.{ name: Http.HeaderName.("x-outer"), value: outer_value }
	reply = Reply.text("wrapped")
		.with_headers([inner_header])
		.with_status(201)
		.with_headers([outer_header])
	response = Respond.to_response(reply)
	response.status == 201 and List.len(response.headers) == 3 and match response.headers {
		[content_type, first, second] =>
			Http.HeaderName.inner(content_type.name) == "content-type"
				and Http.HeaderName.inner(first.name) == "x-inner"
				and Http.HeaderName.inner(second.name) == "x-outer"
		_ => Bool.False
	}
}

expect {
	full = Http.Response.{ status: 202, headers: [], body: Http.ResponseBody.Empty }
	Respond.to_response(Reply.full(full)).status == 202
}

expect {
	Respond.from_result(Err(Reply.status(403))).status == 403
}

expect {
	first : HeaderValue
	first = "a"
	second : HeaderValue
	second = "b"
	kept : HeaderValue
	kept = "k"
	reply = Reply.empty
		.with_headers([
			Http.ResponseHeader.{ name: Http.HeaderName.("X-Request-Id"), value: first },
			Http.ResponseHeader.{ name: Http.HeaderName.("x-kept"), value: kept },
		])
		.replace_headers([Http.ResponseHeader.{ name: Http.HeaderName.("x-request-id"), value: second }])
	Respond.to_response(reply).headers
		== [
			Http.ResponseHeader.{ name: Http.HeaderName.("x-kept"), value: kept },
			Http.ResponseHeader.{ name: Http.HeaderName.("x-request-id"), value: second },
		]
}

# Final metadata appends inside-out and survives unrelated reply wrappers.
expect {
	first = Http.ResponseHeader.{ name: Http.HeaderName.("x-first"), value: "one" }
	last = Http.ResponseHeader.{ name: Http.HeaderName.("x-last"), value: "two" }
	response = Respond.to_response(Reply.text("body").with_trailers([first]).with_status(201).replace_headers([first]).with_trailers([last]))
	response.status == 201 and List.contains(response.headers, first) and response.trailers == [first, last]
}
