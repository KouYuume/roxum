import pf.HeaderName
import pf.RequestHeader
import pf.RequestExecution
import pf.Middleware
import pf.Reply
import GrpcWire
import GrpcMetadata
import GrpcStatus

## A timeout is measured from initial header completion by the host, never from
## handler entry. Large valid durations saturate at U64 nanoseconds.
GrpcTimeout := [].{
	parse : List(U8) -> Try(U64, [InvalidTimeout])
	parse = |bytes| {
		if bytes.len() < 2 or bytes.len() > 9 {
			return Err(InvalidTimeout)
		}
		unit = match bytes.last().map_err(|_| InvalidTimeout)? {
			'H' => 3_600_000_000_000.U64
			'M' => 60_000_000_000
			'S' => 1_000_000_000
			'm' => 1_000_000
			'u' => 1_000
			'n' => 1
			_ => return Err(InvalidTimeout)
		}
		var $value = 0.U64
		for digit in bytes.drop_last(1) {
			if digit < '0' or digit > '9' {
				return Err(InvalidTimeout)
			}
			$value = $value * 10 + (digit - '0').to_u64()
		}
		maximum = 18446744073709551615.U64
		Ok(
			if $value > maximum / unit {
				maximum
			} else {
				$value * unit
			},
		)
	}

	from_headers : List(RequestHeader) -> Try([Absent, Nanoseconds(U64)], [InvalidTimeout])
	from_headers = |headers| {
		var $result = Absent
		for RequestHeader.(header) in headers {
			if HeaderName.inner(header.name) == "grpc-timeout" {
				if $result != Absent {
					return Err(InvalidTimeout)
				}
				$result = Nanoseconds(GrpcTimeout.parse(header.value)?)
			}
		}
		Ok($result)
	}

	## Must precede body waits. Host expiry cancels execution via stream reset;
	## it does not synthesize a gRPC status or preempt pure computation.
	layer = |metadata_limits| [
		Middleware.Stage.BeforeBody(
			|_model, head| {
				_ = GrpcWire.request_metadata(head.version, head.method, head.headers, metadata_limits).map_err(GrpcWire.reject_request)?
				timeout = GrpcTimeout.from_headers(head.headers).map_err(|_| rejection(GrpcStatus.Code.InvalidArgument, "invalid grpc-timeout"))?
				match timeout {
					Absent => {}
					Nanoseconds(duration) => RequestExecution.limit_nanoseconds!(duration).map_err(|_| rejection(GrpcStatus.Code.Internal, "execution control unavailable"))?
				}
				Ok(head)
			},
		),
	]
}

rejection = |code, text| GrpcWire.failure(code, text, [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500)

expect GrpcTimeout.parse("0n".to_utf8()) == Ok(0)
expect GrpcTimeout.parse("99999999H".to_utf8()) == Ok(18446744073709551615)
expect {
	var $ok = Bool.True
	for (unit, multiplier) in [("H", 3600000000000.U64), ("M", 60000000000), ("S", 1000000000), ("m", 1000000), ("u", 1000), ("n", 1)] {
		for value in [0.U64, 1, 2, 9999999, 10000000, 99999999] {
			maximum = 18446744073709551615.U64
			want = if value > maximum / multiplier {
				maximum
			} else {
				value * multiplier
			}
			$ok = $ok and GrpcTimeout.parse("${value.to_str()}${unit}".to_utf8()) == Ok(want)
		}
	}
	$ok
}
expect {
	var $ok = Bool.True
	for text in ["", "n", "1", "-1n", "+1n", "1.0S", "1s", "1 n", " 1n", "1n ", "100000000n", "1n,2n"] {
		$ok = $ok and GrpcTimeout.parse(text.to_utf8()) == Err(InvalidTimeout)
	}
	$ok
}

expect GrpcTimeout.from_headers([]) == Ok(Absent)
expect GrpcTimeout.from_headers([RequestHeader.{ name: HeaderName.("grpc-timeout"), value: "1S".to_utf8() }, RequestHeader.{ name: HeaderName.("grpc-timeout"), value: "2S".to_utf8() }]) == Err(InvalidTimeout)
expect GrpcTimeout.parse("5124094H".to_utf8()) == Ok(18446738400000000000)
expect GrpcTimeout.parse("5124095H".to_utf8()) == Ok(18446742000000000000)
expect GrpcTimeout.parse("5124096H".to_utf8()) == Ok(18446744073709551615)

# Exhaustive byte corpus at both grammar positions, including non-UTF-8 input.
expect {
	var $ok = Bool.True
	var $byte = 0.U16
	while $byte < 256 {
		byte = $byte.to_u8_wrap()
		expected_digit = if byte >= '0' and byte <= '9' {
			Ok((byte - '0').to_u64())
		} else {
			Err(InvalidTimeout)
		}
		$ok = $ok and GrpcTimeout.parse([byte, 'n']) == expected_digit
		is_unit = List.contains(['H', 'M', 'S', 'm', 'u', 'n'], byte)
		$ok = $ok and GrpcTimeout.parse(['1', byte]).is_ok() == is_unit
		$byte = $byte + 1
	}
	$ok
}
