import Extractor
import Http
import HttpError
import Middleware
import MultipartBody
import Reply
import RouteContext
import RequestDecoder
import UrlEncoded

## What a handler made with `Handler.typed` receives: one
## record, whose field types say what to read from the request.
##
## ```roc
## update! : Model, { id : Extract.Path(U64), item : Extract.JsonBody(Item) } => Try(Reply, Reply)
## update! = |model, { id: Extract.Path.(id), item: Extract.JsonBody.(item) }| ...
##
## Router.route("/items/{id}", MethodRouter.put(Handler.typed(update!)))
## ```
##
## A field that cannot be read answers as its extractor in `Extract` does, and
## the handler does not run. A field typed `[Ok(Extract.JsonBody(Item)), Err(Reply)]`
## holds that answer instead, and the handler decides what to do with it. Reading
## has no effects: the body has been received.
## A value that needs effects, such as a user from a database, comes from a
## `BeforeBody` stage through `RequestHead.provided`; a field type of the app's
## reads it with `Extract.reading`.
##
## Extractors for request data, and functions to combine them. Failures are
## `Reply` values built from `HttpError`: malformed input gives 400, and body
## read problems give 408, 413, or 500 as described on `bytes`. JSON media
## type failures give 415.
Extract :: [].{

	## Parser contract for custom typed extractors. Implement `parser_for` with
	## this type and use `Extract.reading` to read the request context.
	Parser(value, provided) : RequestDecoder.Request -> (RequestDecoder.State(provided) -> Try({ value : value, rest : RequestDecoder.State(provided) }, [Rejected(Reply)]))

	## The query string (`Extract.query`).
	Query(value) := value.{
		parser_for : Extract.Parser(Extract.Query(value), provided) where [value.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.query_value(context) {
					Ok(value) => Ok(Extract.Query.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## A multipart/form-data body read whole, into a record (`Extract.multipart`).
	## A file field is an `Extract.Upload`.
	Multipart(value) := value.{
		parser_for : Extract.Parser(Extract.Multipart(value), provided) where [value.MultipartBody.Parseable([Invalid, TooLarge, BadValue, MissingRequiredField(Str), ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.multipart_value(context) {
					Ok(value) => Ok(Extract.Multipart.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## A file field of `Multipart`: `filename`, `content_type`, and `bytes`.
	Upload : MultipartBody.Upload

	## An URL-encoded form body (`Extract.form`).
	Form(value) := value.{
		parser_for : Extract.Parser(Extract.Form(value), provided) where [value.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.form_value(context) {
					Ok(value) => Ok(Extract.Form.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## A JSON body (`Extract.json`).
	JsonBody(value) := value.{
		parser_for : Extract.Parser(Extract.JsonBody(value), provided) where [value.Json.Parseable([InvalidJson(Str), ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.json_value(context) {
					Ok(value) => Ok(Extract.JsonBody.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## The request headers (`Extract.typed_headers`).
	Headers(value) := value.{
		parser_for : Extract.Parser(Extract.Headers(value), provided) where [value.Encoding.HttpHeader.Parseable([BadHeader, ..errs])]
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.headers_value(context) {
					Ok(value) => Ok(Extract.Headers.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## The path parameter with this field's name, as a `Str`, number, or `Bool`.
	## Answers 400 when it does not fit, and 500 when the route has no such
	## parameter, a bug in the app.
	Path(value) := value.{
		parser_for : Extract.Parser(Extract.Path(value), provided) where [value.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, ..errs])]
		parser_for = |_encoding| |state| {
			param = match List.find_first(state.context.path_params, |entry| entry.name == state.field) {
				Ok(found) => found
				Err(_) => return Err(Rejected(Reply.status(500)))
			}
			match UrlEncoded.parse_value(param.value) {
				Ok(value) => Ok({ value: Extract.Path.(value), rest: state })
				Err(_) => Err(Rejected(Reply.status(400)))
			}
		}
	}

	## The whole body.
	Bytes := List(U8).{
		parser_for : Extract.Parser(Extract.Bytes, provided)
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.bytes_value(context) {
					Ok(value) => Ok(Extract.Bytes.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## The whole body as UTF-8.
	Text := Str.{
		parser_for : Extract.Parser(Extract.Text, provided)
		parser_for = |_encoding| Extract.reading(
			|context|
				match Extract.text_value(context) {
					Ok(value) => Ok(Extract.Text.(value))
					Err(reply) => Err(reply)
				},
		)
	}

	## A field type's `parser_for`, from a function of the request: a field type of
	## the app's reads `context.provided` this way.
	##
	## ```roc
	## CurrentUser := User.{
	##     parser_for = |_encoding|
	##         Extract.reading(|context|
	##             match context.provided.user {
	##                 Ok(user) => Ok(CurrentUser.(user))
	##                 Err(_) => Err(Reply.status(500))
	##             })
	## }
	## ```
	reading : (RouteContext(provided) -> Try(value, Reply)) -> (RequestDecoder.State(provided) -> Try({ value : value, rest : RequestDecoder.State(provided) }, [Rejected(Reply)]))
	reading = |read| |state|
		match read(state.context) {
			Ok(value) => Ok({ value, rest: state })
			Err(reply) => Err(Rejected(reply))
		}

	## Runs `extractor` against `context`.
	run! = |extractor, context| (extractor.run!)(context)

	## Transforms the extracted value on success.
	map = |extractor, transform|
		Extractor.{
			run!: |context| {
				value = Extract.run!(extractor, context)?
				Ok(transform(value))
			},
		}

	## Runs two extractors in order and combines their values. Stops at the first
	## failure.
	map2 = |first, second, combine|
		Extractor.{
			run!: |context| {
				first_value = Extract.run!(first, context)?
				second_value = Extract.run!(second, context)?
				Ok(combine(first_value, second_value))
			},
		}

	## Runs three extractors in order and combines their values. Stops at the
	## first failure.
	map3 = |first, second, third, combine|
		Extractor.{
			run!: |context| {
				first_value = Extract.run!(first, context)?
				second_value = Extract.run!(second, context)?
				third_value = Extract.run!(third, context)?
				Ok(combine(first_value, second_value, third_value))
			},
		}

	## Runs `extractor`, then runs the extractor that `next` returns for its value.
	and_then = |extractor, next|
		Extractor.{
			run!: |context| {
				value = Extract.run!(extractor, context)?
				Extract.run!(next(value), context)
			},
		}

	## The whole request.
	request = Extractor.{ run!: |context| Ok(context.request) }

	## The request authority as bytes: the host and optional port from an
	## absolute-form target, otherwise the `Host` header value. Fails with 400 if
	## neither is present.
	authority = Extractor.{
		run!: |context| match Http.Request.authority(context.request) {
			Ok(value) => Ok(value)
			Err(_) => Err(Reply.error(HttpError.bad_request("missing request authority")))
		},
	}

	## The request path as received. It is not percent-decoded and does not
	## include the query.
	path = Extractor.{ run!: |context| Ok(context.request.path) }

	## All path parameters captured by the matched route.
	path_params = Extractor.{ run!: |context| Ok(context.path_params) }

	## The request headers, with lowercase names and raw byte values.
	headers = Extractor.{ run!: |context| Ok(context.request.headers) }

	## The percent-decoded value of the path parameter `name`. Fails with 500 if
	## the matched route has no parameter with that name: the handler asks for
	## a parameter its own route does not declare, which is a bug in the app,
	## not in the request.
	path_param = |name|
		Extractor.{
			run!: |context| {
				for param in context.path_params {
					if param.name == name {
						return Ok(param.value)
					}
				}
				Err(Reply.error(HttpError.internal("missing path parameter: ${name}")))
			},
		}

	## The query string after `?`, without the `?`. It is not percent-decoded.
	## Empty when the target has no query. Fails with 400 if it is not valid UTF-8.
	query_str = Extractor.{
		run!: |context|
			match Str.from_utf8(context.request.query) {
				Ok(value) => Ok(value)
				Err(_) => Err(Reply.error(HttpError.bad_request("query string is not valid UTF-8")))
			},
	}

	## The full request body. The router receives the body before the handler
	## runs, so this reads what it received; running it again gives the
	## same bytes. The body's limits and read failures are answered before the
	## handler runs: 413 over the size limit, 408 on a read timeout, 400 for a
	## malformed body, and 500 for other read failures.
	bytes = Extractor.{ run!: |context| received_body(context.request.body) }

	## The full request body as a string. Fails like `bytes`, and with 400 if the
	## body is not valid UTF-8.
	text = Extractor.{ run!: |context| text_of(context.request.body) }

	## The request body as JSON, into the type the caller's annotation names: `item : Item`, then `item = Extract.run!(Extract.json({}), context)?`.
	## Requires exactly one valid application/json or application/*+json
	## Content-Type (parameters allowed), or answers 415; the body has been received
	## by then, so add `require_json` to refuse before it is. Answers 400 for invalid
	## JSON or a value of another type: Roc's parser does not tell them apart.
	json : {} -> Extractor(a, provided) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json = |{}| Extractor.{ run!: |context| Extract.json_value(context) }

	## What `json` reads, for `Extract.JsonBody`.
	json_value : RouteContext(provided) -> Try(a, Reply) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json_value = |context| {
		if !json_content_type(context.request.headers) {
			return Err(Reply.error(HttpError.make(415, "expected a JSON Content-Type")))
		}
		body_text = text_of(context.request.body)?
		match Json.parse(body_text) {
			Ok(value) => Ok(value)
			Err(_) => Err(Reply.error(HttpError.bad_request("request body is not valid JSON")))
		}
	}

	## The query string, percent-decoded, into the type the caller's annotation
	## names (see `UrlEncoded.Parseable`). Answers 400 for a query past
	## `query_limits` or one that does not fit the type.
	query : {} -> Extractor(a, provided) where [a.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
	query = |{}| Extractor.{ run!: |context| Extract.query_value(context) }

	## What `query` reads, for `Extract.Query`.
	query_value : RouteContext(provided) -> Try(a, Reply) where [a.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
	query_value = |context|
		match UrlEncoded.parse(context.request.query, query_limits) {
			Ok(value) => Ok(value)
			Err(_) => Err(Reply.error(HttpError.bad_request("the query string does not match the target type")))
		}

	## An `application/x-www-form-urlencoded` body, into the type the caller's
	## annotation names. Requires that Content-Type, or answers 415, with
	## `require_form` to refuse before the body is received. Answers 413 past
	## `form_limits`, and 422 for a body that does not fit the type. Only the body
	## is read: a `<form method="get">` arrives in the query, for `query`.
	form : {} -> Extractor(a, provided) where [a.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
	form = |{}| Extractor.{ run!: |context| Extract.form_value(context) }

	## What `form` reads, for `Extract.Form`.
	form_value : RouteContext(provided) -> Try(a, Reply) where [a.UrlEncoded.Parseable([TooManyBytes, TooManyFields, BadValue, MissingRequiredField(Str), ..errs])]
	form_value = |context| {
		if !form_content_type(context.request.headers) {
			return Err(Reply.error(HttpError.make(415, "expected a form Content-Type")))
		}
		body_bytes = received_body(context.request.body)?
		match UrlEncoded.parse(body_bytes, form_limits) {
			Ok(value) => Ok(value)
			Err(TooManyBytes) | Err(TooManyFields) => Err(Reply.error(HttpError.make(413, "form too large")))
			Err(_) => Err(Reply.error(HttpError.make(422, "the form does not match the target type")))
		}
	}

	## The value `pick` reads from what `BeforeBody` stages provided, for a handler that needs it: `Extract.provided(|p| p.user)`. Answers
	## 500 when no stage set it, which means a layer or tag is missing from the
	## route.
	provided = |pick| Extractor.{
		run!: |context|
			match pick(context.provided) {
				Ok(value) => Ok(value)
				Err(_) => Err(Reply.error(HttpError.internal("a value the handler needs was not provided")))
			},
	}

	## The same for a value a stage may leave unset on purpose. `pick` returns
	## `Err(Anonymous)` or the like, which the handler gets; `Err(Unset)`, meaning
	## no stage ran, answers 500.
	optional = |pick| Extractor.{
		run!: |context|
			match pick(context.provided) {
				Err(Unset) => Err(Reply.error(HttpError.internal("a value the handler needs was not provided")))
				Ok(value) => Ok(Ok(value))
				Err(Anonymous) => Ok(Err(Anonymous))
			},
	}

	## A layer that answers 415 before the body is received, unless the request
	## has the Content-Type `json` requires. A client that sent
	## `Expect: 100-continue` then never sends the body. Add it to a route that
	## reads JSON with `MethodRouter.layer`. A function of `{}` because a value
	## cannot be generic over `model`.
	require_json : {} -> List(Middleware.Stage(model, tag, provided))
	require_json = |{}| [
		Middleware.Stage.BeforeBody(
			|_model, head|
				if json_content_type(head.headers) {
					Ok(head)
				} else {
					Err(Reply.error(HttpError.make(415, "expected a JSON Content-Type")))
				},
		),
	]

	## A `multipart/form-data` body, read whole, into the type the caller's
	## annotation names (see `MultipartBody.Parseable`). Requires that Content-Type
	## with a boundary, or answers 415, with `require_multipart` to refuse before the
	## body is received. Answers 400 for a malformed body, 413 past the default
	## `MultipartBody.Limits`, and 422 for a body that does not fit the type. An
	## upload too large to hold uses `Multipart.streaming`.
	multipart : {} -> Extractor(a, provided) where [a.MultipartBody.Parseable([Invalid, TooLarge, BadValue, MissingRequiredField(Str), ..errs])]
	multipart = |{}| Extractor.{ run!: |context| Extract.multipart_value(context) }

	## What `multipart` reads, for `Extract.Multipart`.
	multipart_value : RouteContext(provided) -> Try(a, Reply) where [a.MultipartBody.Parseable([Invalid, TooLarge, BadValue, MissingRequiredField(Str), ..errs])]
	multipart_value = |context| {
		boundary = match multipart_boundary(context.request.headers) {
			Ok(found) => found
			Err(NotMultipart) => return Err(Reply.error(HttpError.make(415, "expected a multipart/form-data Content-Type")))
		}
		body_bytes = received_body(context.request.body)?
		match MultipartBody.parse(body_bytes, boundary, MultipartBody.Limits.{}) {
			Ok(value) => Ok(value)
			Err(Invalid) => Err(Reply.error(HttpError.bad_request("invalid multipart body")))
			Err(TooLarge) => Err(Reply.error(HttpError.make(413, "multipart body too large")))
			Err(_) => Err(Reply.error(HttpError.make(422, "the form does not match the target type")))
		}
	}

	## The same check as `require_json`, for `multipart`.
	require_multipart : {} -> List(Middleware.Stage(model, tag, provided))
	require_multipart = |{}| [
		Middleware.Stage.BeforeBody(
			|_model, head|
				match multipart_boundary(head.headers) {
					Ok(_) => Ok(head)
					Err(NotMultipart) => Err(Reply.error(HttpError.make(415, "expected a multipart/form-data Content-Type")))
				},
		),
	]

	## The same check as `require_json`, for `form`.
	require_form : {} -> List(Middleware.Stage(model, tag, provided))
	require_form = |{}| [
		Middleware.Stage.BeforeBody(
			|_model, head|
				if form_content_type(head.headers) {
					Ok(head)
				} else {
					Err(Reply.error(HttpError.make(415, "expected a form Content-Type")))
				},
		),
	]

	## The request headers, into the type the caller's annotation names. Fails with
	## 400 if a header value is not valid UTF-8 or the headers do not match the type.
	typed_headers : {} -> Extractor(a, provided) where [a.Encoding.HttpHeader.Parseable([BadHeader, ..errs])]
	typed_headers = |{}| Extractor.{ run!: |context| Extract.headers_value(context) }

	## What `typed_headers` reads, for `Extract.Headers`.
	headers_value : RouteContext(provided) -> Try(a, Reply) where [a.Encoding.HttpHeader.Parseable([BadHeader, ..errs])]
	headers_value = |context| {
		raw = headers_to_str(context.request.headers)?
		match (Encoding.HttpHeader.parser_for())(raw) {
			Ok(value) => Ok(value)
			Err(_) => Err(Reply.error(HttpError.bad_request("request headers do not match the target type")))
		}
	}

	## The whole body, for `Extract.Bytes`.
	bytes_value : RouteContext(provided) -> Try(List(U8), Reply)
	bytes_value = |context| received_body(context.request.body)

	## The whole body as UTF-8, for `Extract.Text`.
	text_value : RouteContext(provided) -> Try(Str, Reply)
	text_value = |context| text_of(context.request.body)
}

## The most a query or form may hold.
query_limits = { max_bytes: 8192, max_fields: 128 }

form_limits = { max_bytes: 2 * 1024 * 1024, max_fields: 128 }

text_of = |body| {
	body_bytes = received_body(body)?
	match Str.from_utf8(body_bytes) {
		Ok(value) => Ok(value)
		Err(_) => Err(Reply.error(HttpError.bad_request("request body is not valid UTF-8")))
	}
}

## The body the router received. A `Stream` reaches a handler only when it is
## run outside a router, such as with `Handler.run!` in a test.
received_body = |body|
	match body {
		Http.RequestBody.Empty => Ok([])
		Http.RequestBody.Bytes(body_bytes) => Ok(body_bytes)
		Http.RequestBody.Stream(_) => Err(Reply.error(HttpError.internal("request body was not received")))
	}

headers_to_str = |header_list| {
	var $raw = ""
	for header in header_list {
		name = Http.HeaderName.inner(header.name)
		value = match Str.from_utf8(header.value) {
			Ok(text_value) => text_value
			Err(_) => return Err(Reply.error(HttpError.bad_request("request header value is not valid UTF-8")))
		}
		$raw = $raw.concat(name).concat(": ").concat(value).concat("\r\n")
	}
	Ok($raw)
}

multipart_boundary = |headers|
	match List.keep_if(headers, |field| ascii_lower(Http.HeaderName.inner(field.name)) == "content-type") {
		[field] => MultipartBody.boundary(field.value)
		_ => Err(NotMultipart)
	}

form_content_type = |headers| {
	fields = List.keep_if(headers, |field| ascii_lower(Http.HeaderName.inner(field.name)) == "content-type")
	match fields {
		[field] => form_media_type(field.value)
		_ => Bool.False
	}
}

form_media_type = |bytes| {
	type_part = take_token(skip_ows(bytes))
	if ascii_lower(Str.from_utf8_lossy(type_part.token)) != "application" {
		return Bool.False
	}
	match type_part.rest {
		['/', .. as rest] => {
			sub = take_token(rest)
			ascii_lower(Str.from_utf8_lossy(sub.token)) == "x-www-form-urlencoded" and media_parameters(sub.rest)
		}
		_ => Bool.False
	}
}

expect form_media_type("application/x-www-form-urlencoded".to_utf8())
expect form_media_type("Application/X-WWW-Form-Urlencoded; charset=utf-8".to_utf8())
expect !form_media_type("application/json".to_utf8())
expect !form_media_type("multipart/form-data".to_utf8())
expect !form_media_type("application/x-www-form-urlencoded; charset=".to_utf8())

# Content-Type is a singleton; ambiguity is rejected rather than picking a field.
json_content_type = |headers| {
	fields = List.keep_if(headers, |field| ascii_lower(Http.HeaderName.inner(field.name)) == "content-type")
	match fields {
		[field] => json_media_type(field.value)
		_ => Bool.False
	}
}

ascii_lower = |value| Str.from_utf8_lossy(
	List.map(
		value.to_utf8(),
		|b| if b >= 'A' and b <= 'Z' {
			b + 32
		} else {
			b
		},
	),
)

media_token = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or List.contains("!#$%&'*+-.^_`|~".to_utf8(), b)

skip_ows = |bytes| match bytes {
	[' ', .. as rest] | ['\t', .. as rest] => skip_ows(rest)
	_ => bytes
}

take_token = |bytes| {
	var $count = 0
	for b in bytes {
		if !media_token(b) {
			break
		}
		$count = $count + 1
	}
	{ token: List.take_first(bytes, $count), rest: List.drop_first(bytes, $count) }
}

json_media_type = |bytes| {
	type_part = take_token(skip_ows(bytes))
	if ascii_lower(Str.from_utf8_lossy(type_part.token)) != "application" {
		return Bool.False
	}
	match type_part.rest {
		['/', .. as rest] => {
			sub = take_token(rest)
			name = ascii_lower(Str.from_utf8_lossy(sub.token))
			json = name == "json" or (Str.ends_with(name, "+json") and List.len(sub.token) > 5 and !List.contains(sub.token, '*'))
			json and media_parameters(sub.rest)
		}
		_ => Bool.False
	}
}

# RFC 9110 parameters: token=value or token="quoted value", with OWS at separators.
media_parameters = |bytes| match skip_ows(bytes) {
	[] => Bool.True
	[';', .. as rest] => {
		parameter = take_token(skip_ows(rest))
		if List.is_empty(parameter.token) {
			return Bool.False
		}
		match parameter.rest {
			['=', '"', .. as quoted] => quoted_parameter(quoted)
			['=', .. as value] => {
				parsed = take_token(value)
				!List.is_empty(parsed.token) and media_parameters(parsed.rest)
			}
			_ => Bool.False
		}
	}
	_ => Bool.False
}

quoted_parameter = |bytes| match bytes {
	['"', .. as rest] => media_parameters(rest)
	['\\', b, .. as rest] => (b == 9 or (b >= 32 and b != 127)) and quoted_parameter(rest)
	[b, .. as rest] => (b == 9 or b == 32 or b == 33 or (b >= 35 and b != 92 and b != 127)) and quoted_parameter(rest)
	_ => Bool.False
}

# Media-type equivalence classes: plain, suffix, case, parameters, and non-JSON.
expect json_media_type("application/json".to_utf8())
expect json_media_type("Application/Problem+JSON; charset=utf-8".to_utf8())
expect json_media_type(" application/json ; profile=\"a;b\\\"c\" ".to_utf8())
expect !json_media_type("text/json".to_utf8())
expect !json_media_type("application/jsonx".to_utf8())
expect !json_media_type("application/*+json".to_utf8())
# Suffix prefix length: empty is invalid, one and two token characters are valid.
expect !json_media_type("application/+json".to_utf8())
expect json_media_type("application/a+json".to_utf8())
expect json_media_type("application/ab+json".to_utf8())
# Malformed syntax and singleton ambiguity are not valid media types.
expect !json_media_type("application/json, application/json".to_utf8())
expect !json_media_type("application/json; charset".to_utf8())
expect !json_media_type("application/json; charset=".to_utf8())
expect !json_media_type("application/json; charset=\"utf-8".to_utf8())
expect !json_media_type("application /json".to_utf8())
expect !json_media_type([255])
