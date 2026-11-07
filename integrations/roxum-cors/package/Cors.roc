import pf.HeaderName
import pf.HeaderValue
import pf.Method
import pf.Middleware
import pf.Reply
import pf.Respond
import pf.RequestHead
import pf.RequestHeader
import pf.ResponseHeader

Cors := [].{
	## Safe starting point: no origin is allowed until `origins` is set.
	defaults : Config
	defaults = {
		origins: Exact([]),
		methods: [GET, HEAD, POST],
		headers: [],
		expose_headers: [],
		credentials: Bool.False,
		max_age_seconds: None,
	}

	# Answers CORS preflight requests with 204 before the body is received
	# (`BeforeBody`), and adds CORS fields to other responses from an allowed
	# origin (`AfterHandler`). Apply it with `Router.layer`: preflight requests
	# use OPTIONS, which a route layer never sees because routing answers 405
	# first.
	try_layer :
		Config
		-> Try(List(Middleware.Stage(model, tag, provided)), [CredentialsWithAnyOrigin, InvalidOrigin(Str), InvalidHeaderName(Str)])
	try_layer = |config|
		match prepare(config) {
			Ok(settings) =>
				Ok(
					[
						Middleware.Stage.BeforeBody(
							|_model, head| {
								origin = origin_of(settings, head.headers)
								if is_preflight(head) and origin != NoOrigin {
									Err(Reply.empty.with_status(204).with_headers(preflight_headers(settings, origin)))
								} else {
									Ok(head)
								}
							},
						),
						Middleware.Stage.AfterHandler(
							|_model, head, reply| with_cors_fields(settings, origin_of(settings, head.headers))(reply),
						),
					],
				)
			Err(error) => Err(error)
		}

	layer : Config -> List(Middleware.Stage(model, tag, provided))
	layer = |config|
		match Cors.try_layer(config) {
			Ok(middleware) => middleware
			Err(CredentialsWithAnyOrigin) => crash "roxum-cors: credentials cannot be allowed for any origin"
			Err(InvalidOrigin(origin)) => crash "roxum-cors: origin is not a valid header value: ${origin}"
			Err(InvalidHeaderName(name)) => crash "roxum-cors: header name is not a valid header value: ${name}"
		}
}

# The configuration `layer` takes; start from `Cors.defaults`.
Config : {
	origins : [Any, Exact(List(Str))],
	methods : List(Method),
	headers : List(HeaderName),
	expose_headers : List(HeaderName),
	credentials : Bool,
	max_age_seconds : [None, Value(U64)],
}

# The fields that do not depend on the request, built once by `prepare`.
Settings : {
	origins : [Any, Exact(List(Str))],
	vary : List(ResponseHeader),
	preflight_fields : List(ResponseHeader),
	response_fields : List(ResponseHeader),
}

# Validates the configuration and builds the fixed fields once.
prepare :
	Config
	-> Try(Settings, [CredentialsWithAnyOrigin, InvalidOrigin(Str), InvalidHeaderName(Str)])
prepare = |config| {
	credentials_ok = !(config.credentials and config.origins == Any)
	invalid_origin = match config.origins {
		Any => Ok({})
		Exact(origins) =>
			match List.find_first(origins, |origin| HeaderValue.from_str(origin).is_err()) {
				Ok(origin) => Err(InvalidOrigin(origin))
				Err(_) => Ok({})
			}
	}
	if !credentials_ok {
		Err(CredentialsWithAnyOrigin)
	} else {
		match invalid_origin {
			Err(error) => Err(error)
			Ok({}) =>
				match (names_value(config.headers), names_value(config.expose_headers)) {
					(Err(name), _) => Err(InvalidHeaderName(name))
					(_, Err(name)) => Err(InvalidHeaderName(name))
					(Ok(allow_headers), Ok(expose_headers)) => {
						allow_methods = fixed_value(Str.join_with(List.map(config.methods, Method.to_str), ", "))
						credentials = if config.credentials {
							[field("access-control-allow-credentials", fixed_value("true"))]
						} else {
							[]
						}
						max_age = match config.max_age_seconds {
							None => None
							Value(seconds) => Value(fixed_value(seconds.to_str()))
						}
						Ok(
							{
								origins: config.origins,
								# With an exact origin list the response depends on
								# Origin, so every response says so to shared caches,
								# including responses to other origins.
								vary: match config.origins {
									Any => []
									Exact(_) => [field("vary", fixed_value("Origin"))]
								},
								preflight_fields: [field("access-control-allow-methods", allow_methods)]
									.concat(optional_field("access-control-allow-headers", allow_headers))
									.concat(credentials)
									.concat(optional_field("access-control-max-age", max_age)),
								response_fields: credentials.concat(optional_field("access-control-expose-headers", expose_headers)),
							},
						)
					}
				}
		}
	}
}

# Joins header names for a list field; an empty list adds no field.
names_value : List(HeaderName) -> Try([None, Value(HeaderValue)], Str)
names_value = |names|
	if List.is_empty(names) {
		Ok(None)
	} else {
		joined = Str.join_with(List.map(names, HeaderName.inner), ", ")
		match List.find_first(names, |name| HeaderValue.from_str(HeaderName.inner(name)).is_err()) {
			Ok(name) => Err(HeaderName.inner(name))
			Err(_) => Ok(Value(fixed_value(joined)))
		}
	}

# Values built only from validated names, numbers, and method tokens.
fixed_value : Str -> HeaderValue
fixed_value = |value|
	match HeaderValue.from_str(value) {
		Ok(valid) => valid
		Err(_) => crash "roxum-cors: validated field value contains CR or LF"
	}

# A request is cross-origin only with exactly one Origin field. The value is
# echoed back, so it must be a valid header value.
origin_of : Settings, List(RequestHeader) -> [NoOrigin, Allowed(HeaderValue), Denied]
origin_of = |settings, headers| {
	values = List.map(List.keep_if(headers, |header| header.name == origin_name), |header| header.value)
	match values {
		[bytes] => {
			origin = Str.from_utf8_lossy(bytes)
			allowed = match settings.origins {
				Any => Bool.True
				Exact(origins) => List.contains(origins, origin)
			}
			match (allowed, HeaderValue.from_str(origin)) {
				(Bool.True, Ok(value)) => Allowed(value)
				_ => Denied
			}
		}
		_ => NoOrigin
	}
}

is_preflight : RequestHead(tag, provided) -> Bool
is_preflight = |head|
	head.method == OPTIONS
		and List.any(head.headers, |header| header.name == HeaderName.("access-control-request-method"))

allow_origin : Settings, HeaderValue -> ResponseHeader
allow_origin = |settings, origin|
	match settings.origins {
		Any => field("access-control-allow-origin", fixed_value("*"))
		Exact(_) => field("access-control-allow-origin", origin)
	}

optional_field : Str, [None, Value(HeaderValue)] -> List(ResponseHeader)
optional_field = |name, value|
	match value {
		None => []
		Value(present) => [field(name, present)]
	}

preflight_headers : Settings, [NoOrigin, Allowed(HeaderValue), Denied] -> List(ResponseHeader)
preflight_headers = |settings, origin|
	match origin {
		Allowed(value) => [allow_origin(settings, value)].concat(settings.vary).concat(settings.preflight_fields)
		_ => settings.vary
	}

response_headers : Settings, [NoOrigin, Allowed(HeaderValue), Denied] -> List(ResponseHeader)
response_headers = |settings, origin|
	match origin {
		Allowed(value) => [allow_origin(settings, value)].concat(settings.vary).concat(settings.response_fields)
		_ => settings.vary
	}

# Applies this policy even when it grants nothing. Keep unrelated fields and
# append Vary, but remove all grants left by inner handlers or middleware.
with_cors_fields : Settings, [NoOrigin, Allowed(HeaderValue), Denied] -> (Reply -> Reply)
with_cors_fields = |settings, origin| {
	fields = response_headers(settings, origin)
	|reply| {
		response = Respond.to_response(reply)
		kept = List.drop_if(response.headers, |header| cors_owned(header.name))
		Reply.full({ ..response, headers: kept.concat(fields) })
	}
}

cors_owned : HeaderName -> Bool
cors_owned = |name| {
	lower = Str.from_utf8_lossy(
		HeaderName.inner(name).to_utf8().map(
			|byte| if byte >= 'A' and byte <= 'Z' {
				byte + 32
			} else {
				byte
			},
		),
	)
	["access-control-allow-origin", "access-control-allow-credentials", "access-control-allow-methods", "access-control-allow-headers", "access-control-expose-headers", "access-control-max-age"].contains(lower)
}

field : Str, HeaderValue -> ResponseHeader
field = |name, value| ResponseHeader.{ name: HeaderName.(name), value }

origin_name : HeaderName
origin_name = HeaderName.("origin")

exact_config = {
	..Cors.defaults,
	origins: Exact(["https://app.example"]),
	methods: [GET, POST],
	headers: [HeaderName.("content-type"), HeaderName.("x-token")],
	expose_headers: [HeaderName.("x-request-id")],
	credentials: Bool.True,
	max_age_seconds: Value(600),
}

any_config = { ..Cors.defaults, origins: Any }

# Runs a check against the prepared settings; an invalid test configuration fails the check.
with_settings = |config, check|
	match prepare(config) {
		Ok(settings) => check(settings)
		Err(_) => Bool.False
	}

origin_field = |value| RequestHeader.{ name: origin_name, value: value.to_utf8() }

value = |text| fixed_value(text)

# Credentials are rejected only together with any origin.
expect
	match prepare({ ..any_config, credentials: Bool.True }) {
		Err(CredentialsWithAnyOrigin) => Bool.True
		_ => Bool.False
	}
expect with_settings({ ..Cors.defaults, origins: Exact(["https://app.example"]), credentials: Bool.True }, |_| Bool.True)
expect with_settings({ ..any_config, credentials: Bool.False }, |_| Bool.True)

expect
	match prepare({ ..Cors.defaults, origins: Exact(["https://app.example\r\n"]) }) {
		Err(InvalidOrigin(_)) => Bool.True
		_ => Bool.False
	}

expect
	match prepare({ ..Cors.defaults, headers: [HeaderName.("x-bad\n")] }) {
		Err(InvalidHeaderName(_)) => Bool.True
		_ => Bool.False
	}

# Origin field count: none and repeated fields are not cross-origin requests.
expect with_settings(exact_config, |settings| origin_of(settings, []) == NoOrigin)
expect with_settings(exact_config, |settings| origin_of(settings, [origin_field("https://app.example")]) == Allowed(value("https://app.example")))
expect with_settings(exact_config, |settings| origin_of(settings, [origin_field("https://app.example"), origin_field("https://app.example")]) == NoOrigin)

# Exact origins compare the whole serialized origin.
expect with_settings(exact_config, |settings| origin_of(settings, [origin_field("https://evil.example")]) == Denied)
expect with_settings(exact_config, |settings| origin_of(settings, [origin_field("https://APP.example")]) == Denied)
expect with_settings(exact_config, |settings| origin_of(settings, [origin_field("https://app.example:443")]) == Denied)
expect with_settings(any_config, |settings| origin_of(settings, [origin_field("https://evil.example")]) == Allowed(value("https://evil.example")))

expect
	with_settings(
		exact_config,
		|settings|
			response_headers(settings, Allowed(value("https://app.example")))
			== [
				field("access-control-allow-origin", value("https://app.example")),
				field("vary", value("Origin")),
				field("access-control-allow-credentials", value("true")),
				field("access-control-expose-headers", value("x-request-id")),
			],
	)

expect with_settings(exact_config, |settings| response_headers(settings, Denied) == [field("vary", value("Origin"))])
expect with_settings(exact_config, |settings| response_headers(settings, NoOrigin) == [field("vary", value("Origin"))])
expect with_settings(any_config, |settings| response_headers(settings, Allowed(value("https://a.example"))) == [field("access-control-allow-origin", value("*"))])
expect with_settings(any_config, |settings| response_headers(settings, NoOrigin) == [])

expect
	with_settings(
		exact_config,
		|settings|
			preflight_headers(settings, Allowed(value("https://app.example")))
			== [
				field("access-control-allow-origin", value("https://app.example")),
				field("vary", value("Origin")),
				field("access-control-allow-methods", value("GET, POST")),
				field("access-control-allow-headers", value("content-type, x-token")),
				field("access-control-allow-credentials", value("true")),
				field("access-control-max-age", value("600")),
			],
	)

expect with_settings(exact_config, |settings| preflight_headers(settings, Denied) == [field("vary", value("Origin"))])

# Defaults: HEAD is included, and optional fields are omitted.
expect
	with_settings(
		any_config,
		|settings|
			preflight_headers(settings, Allowed(value("https://a.example")))
			== [
				field("access-control-allow-origin", value("*")),
				field("access-control-allow-methods", value("GET, HEAD, POST")),
			],
	)

# Max-age boundary: zero is sent, None is omitted.
expect
	with_settings(
		{ ..any_config, max_age_seconds: Value(0) },
		|settings| List.contains(preflight_headers(settings, Allowed(value("https://a.example"))), field("access-control-max-age", value("0"))),
	)

# Policy classes: allowed, denied, absent Origin; with/without credentials.
# Inner grants must never survive merely because the outer policy omits them.
expect List.all(
	[Bool.False, Bool.True],
	|credentials|
		with_settings(
			{ ..exact_config, credentials },
			|settings|
				List.all(
					[Allowed(value("https://app.example")), Denied, NoOrigin],
					|origin| {
						kept = field("vary", value("Accept-Encoding"))
						inner = Reply.status(202)
							.with_headers([
								kept,
								field("x-kept", value("yes")),
								field("Access-Control-Allow-Origin", value("https://evil.example")),
								field("Access-Control-Allow-Credentials", value("true")),
								field("Access-Control-Expose-Headers", value("x-secret")),
								field("Access-Control-Allow-Methods", value("DELETE")),
								field("Access-Control-Allow-Headers", value("x-secret")),
								field("Access-Control-Max-Age", value("999")),
							])
						response = Respond.to_response(with_cors_fields(settings, origin)(inner))
						response.status == 202 and response.headers == [kept, field("x-kept", value("yes"))].concat(response_headers(settings, origin))
					},
				),
		),
)
