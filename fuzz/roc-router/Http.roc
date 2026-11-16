import HeaderValue

# Fuzz-only shape-compatible subset. The production Http module's hosted body
# read effect cannot be bound by the roc-fuzz platform; Router only depends on
# these fields and variants.
Http :: [].{
	Method := [OPTIONS, GET, HEAD, POST, PUT, DELETE, PATCH, QUERY].{
		is_eq : _
		to_str : Http.Method -> Str
		to_str = |method|
			match method {
				OPTIONS => "OPTIONS"
				GET => "GET"
				HEAD => "HEAD"
				POST => "POST"
				PUT => "PUT"
				DELETE => "DELETE"
				PATCH => "PATCH"
				QUERY => "QUERY"
			}
	}
	Version := [Http10, Http11].{ is_eq : _ }
	IpAddr := [V4((U8, U8, U8, U8)), V6((U16, U16, U16, U16, U16, U16, U16, U16))].{ is_eq : _ }
	RemoteAddr := { ip : Http.IpAddr, port : U16 }.{ is_eq : _ }
	HeaderName := Str.{
		is_eq : _
		to_hash : _
		inner = |HeaderName.(value)| value
	}
	RequestHeader := { name : Http.HeaderName, value : List(U8) }.{ is_eq : _ }
	ResponseHeader := { name : Http.HeaderName, value : HeaderValue }.{ is_eq : _ }
	RequestBody := [Empty, Bytes(List(U8))]
	ResponseBody := [Empty, Bytes(List(U8))]
	Request := {
		method : Http.Method,
		version : Http.Version,
		raw_target : List(U8),
		path : Str,
		query : List(U8),
		headers : List(Http.RequestHeader),
		body : Http.RequestBody,
		remote_addr : Http.RemoteAddr,
		request_id : Str,
	}
	Response := { status : U16, headers : List(Http.ResponseHeader), trailers : List(Http.ResponseHeader) ?? [], body : Http.ResponseBody }
}
