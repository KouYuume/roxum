import Http

HostRequestExecution := [].{
	Elapsed := [Elapsed(U64), Unavailable]
	elapsed_nanoseconds! : {} => HostRequestExecution.Elapsed
	limit_nanoseconds! : U64 => Bool
	limit_with_response! : U64, Http.Response => U8
}
