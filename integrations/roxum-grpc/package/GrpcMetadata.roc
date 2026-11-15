import pf.HeaderName
import pf.HeaderValue
import pf.RequestHeader
import pf.ResponseHeader
import GrpcBase64

## Ordered metadata entries preserve duplicate values. Binary names include -bin.
GrpcMetadata := [].{
	Entry := [Text(Str, Str), Binary(Str, List(U8))].{
		is_eq : _
	}
	Limits : { bytes : U64, entries : U64 }
	defaults : GrpcMetadata.Limits
	defaults = { bytes: 8192, entries: 62 }
	Error : [MetadataLimit, InvalidMetadata, InvalidBase64]

	## Counts all received fields, including protocol fields. Invalid HTTP-valid
	## non-ASCII custom text values are discarded rather than rejecting the RPC.
	decode : List(RequestHeader), GrpcMetadata.Limits -> Try(List(GrpcMetadata.Entry), GrpcMetadata.Error)
	decode = |headers, limits| {
		var $remaining = limits.bytes
		var $out = []
		for RequestHeader.(field) in headers {
			name = HeaderName.inner(field.name)
			$remaining = charge($remaining, name.to_utf8().len(), field.value.len())?
			if !reserved(name) {
				if !valid_name(name) {
					return Err(InvalidMetadata)
				}
				if name.ends_with("-bin") {
					# Split before Base64 decoding; comma-joined values retain
					# their order and each consumes an entry, even when empty.
					for part in field.value.split_on(',') {
						if $out.len() >= limits.entries {
							return Err(MetadataLimit)
						}
						value = GrpcBase64.decode(trim(part))?
						$out = $out.append(GrpcMetadata.Entry.Binary(name, value))
					}
				} else if printable(field.value) {
					if $out.len() >= limits.entries {
						return Err(MetadataLimit)
					}
					$out = $out.append(GrpcMetadata.Entry.Text(name, Str.from_utf8(trim(field.value)) ?? ""))
				}
			}
		}
		Ok($out)
	}

	encode : List(GrpcMetadata.Entry), GrpcMetadata.Limits -> Try(List(ResponseHeader), GrpcMetadata.Error)
	encode = |entries, limits| {
		if entries.len() > limits.entries {
			return Err(MetadataLimit)
		}
		var $remaining = limits.bytes
		var $out = []
		for entry in entries {
			(field_name, raw_value) = match entry {
				Text(name, text) => {
					if name.ends_with("-bin") or !printable(text.to_utf8()) {
						return Err(InvalidMetadata)
					}
					normalized = Str.from_utf8(trim(text.to_utf8())) ?? ""
					$remaining = charge($remaining, name.to_utf8().len(), normalized.to_utf8().len())?
					(name, normalized)
				}
				Binary(name, bytes) => {
					if !name.ends_with("-bin") {
						return Err(InvalidMetadata)
					}
					# Charge encoded bytes before allocating Base64 output.
					if bytes.len() > $remaining {
						return Err(MetadataLimit)
					}
					size = bytes.len() / 3 * 4 + if bytes.len() % 3 == 0 {
						0
					} else {
						bytes.len() % 3 + 1
					}
					$remaining = charge($remaining, name.to_utf8().len(), size)?
					(name, GrpcBase64.encode(bytes))
				}
			}
			if !valid_name(field_name) or reserved(field_name) {
				return Err(InvalidMetadata)
			}
			value = HeaderValue.from_str(raw_value).map_err(|_| InvalidMetadata)?
			$out = $out.append(ResponseHeader.{ name: HeaderName.(field_name), value })
		}
		Ok($out)
	}
}

charge = |remaining, name, value| {
	if remaining < 32 {
		return Err(MetadataLimit)
	}
	available = remaining - 32
	if name > available or value > available - name {
		return Err(MetadataLimit)
	}
	Ok(available - name - value)
}

valid_name = |name| !name.is_empty() and name.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_' or byte == '.')

printable = |bytes| bytes.all(|byte| byte >= 32 and byte <= 126)

reserved = |name| name.starts_with("grpc-") or name.starts_with(":") or List.contains(["content-type", "content-length", "te", "host", "user-agent", "accept-encoding", "content-encoding", "connection", "keep-alive", "proxy-connection", "upgrade", "transfer-encoding", "trailer"], name)

trim = |bytes| {
	var $out = bytes
	while !$out.is_empty() and ($out.first() == Ok(' ') or $out.first() == Ok('\t')) {
		$out = $out.drop_first(1)
	}
	while !$out.is_empty() and ($out.last() == Ok(' ') or $out.last() == Ok('\t')) {
		$out = $out.drop_last(1)
	}
	$out
}
expect {
	headers = [RequestHeader.{ name: HeaderName.("x-bin"), value: "Zg==, Zm8".to_utf8() }]
	GrpcMetadata.decode(headers, GrpcMetadata.defaults) == Ok([GrpcMetadata.Entry.Binary("x-bin", [102]), GrpcMetadata.Entry.Binary("x-bin", [102, 111])])
}
expect GrpcMetadata.decode([RequestHeader.{ name: HeaderName.("x"), value: [255] }], GrpcMetadata.defaults) == Ok([])
expect GrpcMetadata.encode([GrpcMetadata.Entry.Text("grpc-status", "0")], GrpcMetadata.defaults) == Err(InvalidMetadata)
expect GrpcMetadata.encode([GrpcMetadata.Entry.Text("x-bin", "abc")], GrpcMetadata.defaults) == Err(InvalidMetadata)
expect GrpcMetadata.encode([GrpcMetadata.Entry.Text("x", "\r\n")], GrpcMetadata.defaults) == Err(InvalidMetadata)
expect {
	var $ok = Bool.True
	for bytes in [33.U64, 34, 35] {
		result = GrpcMetadata.encode([GrpcMetadata.Entry.Text("x", "a")], { bytes, entries: 1 })
		$ok = $ok and if bytes < 34 {
			result == Err(MetadataLimit)
		} else {
			result.is_ok()
		}
	}
	$ok
}
expect GrpcMetadata.decode([RequestHeader.{ name: HeaderName.("x-bin"), value: ",,".to_utf8() }], { bytes: 64, entries: 2 }) == Err(MetadataLimit)

expect {
	var $ok = Bool.True
	for bytes in [33.U64, 34, 35] {
		result = GrpcMetadata.decode([RequestHeader.{ name: HeaderName.("x"), value: [97] }], { bytes, entries: 1 })
		$ok = $ok and if bytes < 34 {
			result == Err(MetadataLimit)
		} else {
			result == Ok([GrpcMetadata.Entry.Text("x", "a")])
		}
	}
	$ok
}

# HTTP/2 field values cannot begin or end with whitespace; charge wire bytes.
expect {
	var $ok = Bool.True
	for (input, output) in [("", ""), ("   ", ""), (" a ", "a"), (" a b ", "a b")] {
		encoded = GrpcMetadata.encode([GrpcMetadata.Entry.Text("x", input)], { bytes: 33 + output.to_utf8().len(), entries: 1 })?
		field = encoded.first()?
		ResponseHeader.(value) = field
		$ok = $ok and HeaderValue.inner(value.value) == output
	}
	$ok
}
