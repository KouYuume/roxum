import Http

HostRequestExecution := [].{
	DecodeInput := [Input(List(U8)), Unavailable, Exhausted]
	begin_decode! : List(U8) => HostRequestExecution.DecodeInput
	DecodeFallback := [Finite(Http.Response), Stream({ remaining : List(U8), trailers : List(Http.ResponseHeader) })]
	begin_decode_with_fallback! : List(U8), HostRequestExecution.DecodeFallback => HostRequestExecution.DecodeInput
	end_decode! : {} => {}
	Elapsed := [Elapsed(U64), Unavailable]
	elapsed_nanoseconds! : {} => HostRequestExecution.Elapsed
	limit_nanoseconds! : U64 => Bool
	limit_with_response! : U64, Http.Response => U8
	limit_with_trailers! : U64, List(Http.ResponseHeader) => U8
}
