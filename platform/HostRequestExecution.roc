import Http

HostRequestExecution := [].{
	Elapsed := [Elapsed(U64), Unavailable]
	elapsed_nanoseconds! : {} => HostRequestExecution.Elapsed
	limit_nanoseconds! : U64 => Bool
	limit_with_response! : U64, Http.Response => U8
	limit_with_trailers! : U64, List(Http.ResponseHeader) => U8
}
