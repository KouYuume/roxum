## Standard gRPC status codes and bounded UTF-8 percent encoding.
GrpcStatus := [].{
	Code := [Ok, Cancelled, Unknown, InvalidArgument, DeadlineExceeded, NotFound, AlreadyExists, PermissionDenied, ResourceExhausted, FailedPrecondition, Aborted, OutOfRange, Unimplemented, Internal, Unavailable, DataLoss, Unauthenticated].{
		is_eq : _
	}
	number : GrpcStatus.Code -> U32
	number = |code| match code {
		Ok => 0
		Cancelled => 1
		Unknown => 2
		InvalidArgument => 3
		DeadlineExceeded => 4
		NotFound => 5
		AlreadyExists => 6
		PermissionDenied => 7
		ResourceExhausted => 8
		FailedPrecondition => 9
		Aborted => 10
		OutOfRange => 11
		Unimplemented => 12
		Internal => 13
		Unavailable => 14
		DataLoss => 15
		Unauthenticated => 16
	}

	encode_message : Str, U64 -> Try(Str, [StatusLimit])
	encode_message = |message, maximum| {
		bytes = message.to_utf8()
		if bytes.len() > maximum {
			return Err(StatusLimit)
		}
		var $out = []
		for byte in bytes {
			if byte >= 33 and byte <= 126 and byte != '%' {
				if $out.len() >= maximum {
					return Err(StatusLimit)
				}
				$out = $out.append(byte)
			} else {
				if maximum - $out.len() < 3 {
					return Err(StatusLimit)
				}
				$out = $out.concat(['%', hex(byte / 16), hex(byte % 16)])
			}
		}
		Ok(Str.from_utf8($out) ?? "")
	}
}

hex = |byte| "0123456789ABCDEF".to_utf8().get(byte.to_u64()) ?? '0'
expect GrpcStatus.encode_message("%\n", 6) == Ok("%25%0A")
expect GrpcStatus.encode_message("é", 6) == Ok("%C3%A9")
expect GrpcStatus.encode_message("é", 5) == Err(StatusLimit)
expect GrpcStatus.encode_message("é", 7) == Ok("%C3%A9")
expect GrpcStatus.encode_message("", 0) == Ok("")
expect GrpcStatus.number(GrpcStatus.Code.Ok) == 0
expect GrpcStatus.number(GrpcStatus.Code.Cancelled) == 1
expect GrpcStatus.number(GrpcStatus.Code.Unknown) == 2
expect GrpcStatus.number(GrpcStatus.Code.InvalidArgument) == 3
expect GrpcStatus.number(GrpcStatus.Code.DeadlineExceeded) == 4
expect GrpcStatus.number(GrpcStatus.Code.NotFound) == 5
expect GrpcStatus.number(GrpcStatus.Code.AlreadyExists) == 6
expect GrpcStatus.number(GrpcStatus.Code.PermissionDenied) == 7
expect GrpcStatus.number(GrpcStatus.Code.ResourceExhausted) == 8
expect GrpcStatus.number(GrpcStatus.Code.FailedPrecondition) == 9
expect GrpcStatus.number(GrpcStatus.Code.Aborted) == 10
expect GrpcStatus.number(GrpcStatus.Code.OutOfRange) == 11
expect GrpcStatus.number(GrpcStatus.Code.Unimplemented) == 12
expect GrpcStatus.number(GrpcStatus.Code.Internal) == 13
expect GrpcStatus.number(GrpcStatus.Code.Unavailable) == 14
expect GrpcStatus.number(GrpcStatus.Code.DataLoss) == 15
expect GrpcStatus.number(GrpcStatus.Code.Unauthenticated) == 16

# Escaped spaces preserve text without producing forbidden HTTP/2 edge whitespace.
expect GrpcStatus.encode_message(" a b ", 11) == Ok("%20a%20b%20")
expect GrpcStatus.encode_message(" ", 2) == Err(StatusLimit)
expect GrpcStatus.encode_message(" ", 3) == Ok("%20")
expect GrpcStatus.encode_message(" ", 4) == Ok("%20")
