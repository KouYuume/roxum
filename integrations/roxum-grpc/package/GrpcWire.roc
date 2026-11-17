import pf.HeaderName
import pf.HeaderValue
import pf.Method
import pf.RequestHeader
import pf.ResponseHeader
import pf.Reply
import pf.Version
import GrpcFrame
import GrpcMetadata
import GrpcStatus

## Protocol fields and finite replies; typed integrations own dispatch, schema
## decoding and deadlines. Validate request metadata before decoding the body.
GrpcWire := [].{
	RequestError : [HttpVersion, HttpMethod, ContentType, InvalidHeaders, UnsupportedEncoding, MetadataLimit, InvalidMetadata, InvalidBase64]
	ResponseError : [MessageLimit, MetadataLimit, InvalidMetadata, InvalidBase64, StatusLimit, InvalidStatus]

	request_metadata : Version, Method, List(RequestHeader), GrpcMetadata.Limits -> Try(List(GrpcMetadata.Entry), GrpcWire.RequestError)
	request_metadata = |version, method, headers, limits| {
		if version != Version.Http20 {
			return Err(HttpVersion)
		}
		if method != Method.POST {
			return Err(HttpMethod)
		}
		metadata = GrpcMetadata.decode(headers, limits)?
		content_type = (single(headers, "content-type")?.split_on(";").first() ?? "").trim()
		if !content_type.caseless_ascii_equals("application/grpc") and !content_type.caseless_ascii_equals("application/grpc+proto") {
			return Err(ContentType)
		}
		if !single(headers, "te")?.trim().caseless_ascii_equals("trailers") {
			return Err(InvalidHeaders)
		}
		encoding = single(headers, "grpc-encoding")?
		if encoding != "" and encoding != "identity" {
			return Err(UnsupportedEncoding)
		}
		content_encoding = single(headers, "content-encoding")?
		if content_encoding != "" and content_encoding != "identity" {
			return Err(UnsupportedEncoding)
		}
		Ok(metadata)
	}

	## These mappings cover integration validation, not host admission failures.
	reject_request : GrpcWire.RequestError -> Reply
	reject_request = |error| match error {
		HttpVersion => Reply.text("gRPC requires HTTP/2").with_status(400)
		HttpMethod => Reply.text("gRPC requires POST").with_status(405)
		ContentType => Reply.text("unsupported gRPC media type").with_status(415)
		UnsupportedEncoding => failure_reply(GrpcStatus.Code.Unimplemented, "unsupported message encoding")
		MetadataLimit => failure_reply(GrpcStatus.Code.ResourceExhausted, "metadata limit")
		InvalidHeaders | InvalidMetadata | InvalidBase64 => failure_reply(GrpcStatus.Code.InvalidArgument, "invalid metadata")
	}

	reject_frame : GrpcFrame.Error -> Reply
	reject_frame = |error| match error {
		MessageLimit => failure_reply(GrpcStatus.Code.ResourceExhausted, "message limit")
		UnsupportedCompression => failure_reply(GrpcStatus.Code.Unimplemented, "compressed messages are unsupported")
		MissingMessage | Truncated | InvalidFlag | ExtraMessage => failure_reply(GrpcStatus.Code.InvalidArgument, "invalid Unary message envelope")
	}

	success : List(U8), List(GrpcMetadata.Entry), List(GrpcMetadata.Entry), { message_bytes : U64, metadata : GrpcMetadata.Limits } -> Try(Reply, GrpcWire.ResponseError)
	success = |message, initial, trailing, limits| {
		body = GrpcFrame.encode(message, limits.message_bytes)?
		headers = GrpcMetadata.encode(initial, response_limits(limits.metadata))?
		trailers = trailer_fields(trailing, response_limits(limits.metadata))?
		Ok(Reply.bytes(body, "application/grpc+proto").with_headers(headers).with_trailers(trailers.append(ResponseHeader.{ name: HeaderName.("grpc-status"), value: "0" })))
	}

	## Shared validation for streamed initial metadata and terminal status.
	initial_fields = |metadata, limits| GrpcMetadata.encode(metadata, response_limits(limits))

	terminal_fields = |code, message, trailing, limits| {
		trailers = trailer_fields(trailing, response_limits(limits.metadata))?
		encoded = GrpcStatus.encode_message(message, limits.status_bytes)?
		status = HeaderValue.from_str(GrpcStatus.number(code).to_str()).map_err(|_| InvalidMetadata)?
		detail = HeaderValue.from_str(encoded).map_err(|_| InvalidMetadata)?
		Ok(
			trailers.concat([
				ResponseHeader.{ name: HeaderName.("grpc-status"), value: status },
				ResponseHeader.{ name: HeaderName.("grpc-message"), value: detail },
			]),
		)
	}

	failure : GrpcStatus.Code, Str, List(GrpcMetadata.Entry), { status_bytes : U64, metadata : GrpcMetadata.Limits } -> Try(Reply, GrpcWire.ResponseError)
	failure = |code, message, trailing, limits| {
		if code == GrpcStatus.Code.Ok {
			return Err(InvalidStatus)
		}
		trailers = trailer_fields(trailing, response_limits(limits.metadata))?
		encoded = GrpcStatus.encode_message(message, limits.status_bytes)?
		status = HeaderValue.from_str(GrpcStatus.number(code).to_str()).map_err(|_| InvalidMetadata)?
		detail = HeaderValue.from_str(encoded).map_err(|_| InvalidMetadata)?
		Ok(
			Reply.bytes([], "application/grpc+proto").with_trailers(
				trailers.concat([
					ResponseHeader.{ name: HeaderName.("grpc-status"), value: status },
					ResponseHeader.{ name: HeaderName.("grpc-message"), value: detail },
				]),
			),
		)
	}
}

single = |headers, wanted| {
	var $found = Bool.False
	var $value = ""
	for RequestHeader.(header) in headers {
		if HeaderName.inner(header.name) == wanted {
			if $found {
				return Err(InvalidHeaders)
			}
			$found = Bool.True
			$value = Str.from_utf8(header.value).map_err(|_| InvalidHeaders)?
			if $value.is_empty() {
				return Err(InvalidHeaders)
			}
		}
	}
	Ok($value)
}

failure_reply = |code, message| GrpcWire.failure(code, message, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.text("gRPC response failure").with_status(500)

# The finite HTTP/2 host allows 64 fields per block. Reserve two for protocol
# fields (content type/length, or status/message), even with custom larger limits.
response_limits = |limits| {
	..limits,
	entries: if limits.entries > 62 {
		62
	} else {
		limits.entries
	},
}

trailer_fields = |metadata, limits| {
	fields = GrpcMetadata.encode(metadata, limits)?
	for ResponseHeader.(field) in fields {
		if List.contains(["authorization", "proxy-authorization", "www-authenticate", "proxy-authenticate", "content-range"], HeaderName.inner(field.name)) {
			return Err(InvalidMetadata)
		}
	}
	Ok(fields)
}
expect match GrpcWire.failure(GrpcStatus.Code.InvalidArgument, "", [GrpcMetadata.Entry.Text("authorization", "secret")], { status_bytes: 64, metadata: GrpcMetadata.defaults }) {
	Err(InvalidMetadata) => Bool.True
	_ => Bool.False
}
expect match GrpcWire.success([], List.repeat(GrpcMetadata.Entry.Text("x", "y"), 63), [], { message_bytes: 64, metadata: { bytes: 8192, entries: 100 } }) {
	Err(MetadataLimit) => Bool.True
	_ => Bool.False
}

# Reject transport-only fields before the host attempts to encode a response.
expect {
	var $ok = Bool.True
	for name in ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te"] {
		metadata = [GrpcMetadata.Entry.Text(name, "value")]
		$ok = $ok and match GrpcWire.success([], metadata, [], { message_bytes: 64, metadata: GrpcMetadata.defaults }) {
			Err(InvalidMetadata) => Bool.True
			_ => Bool.False
		}
		$ok = $ok and match GrpcWire.failure(GrpcStatus.Code.Internal, "", metadata, { status_bytes: 64, metadata: GrpcMetadata.defaults }) {
			Err(InvalidMetadata) => Bool.True
			_ => Bool.False
		}
	}
	$ok
}
