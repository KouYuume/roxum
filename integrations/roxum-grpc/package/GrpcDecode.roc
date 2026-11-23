import pf.RequestExecution
import GrpcStatus

GrpcDecode := [].{
	message! = |bytes, decode| {
		result = RequestExecution.decode_bytes!(bytes, decode).map_err(
			|reason|
				match reason {
					Exhausted => (GrpcStatus.Code.ResourceExhausted, "message allocation limit")
					Unavailable => (GrpcStatus.Code.Internal, "decoder unavailable")
				},
		)?
		result.map_err(|_| (GrpcStatus.Code.InvalidArgument, "invalid Protobuf message"))
	}
}
