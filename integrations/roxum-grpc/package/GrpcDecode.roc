import pf.RequestExecution
import pf.Respond
import pf.Reply
import GrpcWire
import GrpcMetadata
import GrpcStatus

GrpcDecode := [].{
	message! = |bytes, decode|
		map_result(RequestExecution.decode_bytes_with_response!(bytes, exhausted_response, decode))

	duplex_message! = |bytes, remaining, decode|
		map_result(RequestExecution.decode_bytes_with_completion!(bytes, { remaining, trailers: exhausted_response.trailers }, decode))
}

map_result = |decoded| {
	result = decoded.map_err(
		|reason|
			match reason {
				Exhausted => (GrpcStatus.Code.ResourceExhausted, "message allocation limit")
				Unavailable => (GrpcStatus.Code.Internal, "decoder unavailable")
			},
	)?
	result.map_err(|_| (GrpcStatus.Code.InvalidArgument, "invalid Protobuf message"))
}

exhausted_response = Respond.to_response(GrpcWire.failure(GrpcStatus.Code.ResourceExhausted, "message allocation limit", [], { status_bytes: 128, metadata: GrpcMetadata.defaults }) ?? Reply.status(500))
