import HostRequestExecution

## Execution timing for the current HTTP/2 request. These effects are unavailable
## in `init!` and on HTTP/1. They carry no handle that can escape the request.
##
## Initial header completion is the immutable time origin. Body reception,
## queueing, and handler execution all count. Finite HTTP/2 handlers currently
## run after the body arrives; these operations do not provide early dispatch.
RequestExecution := [].{
	## Elapsed monotonic nanoseconds since initial headers completed.
	## An expired or closed request stops instead of returning to application code.
	elapsed_nanoseconds! : {} => Try(U64, [Unavailable])
	elapsed_nanoseconds! = |{}|
		match HostRequestExecution.elapsed_nanoseconds!({}) {
			Elapsed(nanoseconds) => Ok(nanoseconds)
			Unavailable => Err(Unavailable)
		}

	## Bounds execution by a duration from initial header completion, not from
	## this call. Repeated calls only tighten the deadline, including the server's
	## `Server.Limits.http2_execution` cap. Addition saturates rather than wrapping.
	## Zero, or a duration already elapsed, stops this request before returning.
	##
	## Expiry resets the HTTP/2 stream and cancels suspended I/O; it does not create
	## an HTTP reply or a gRPC status. It cannot preempt arbitrary pure computation.
	## Response commitment wins over later expiry; socket writes still have their
	## own timeout. This does not change idle/read/write timeouts.
	limit_nanoseconds! : U64 => Try({}, [Unavailable])
	limit_nanoseconds! = |nanoseconds|
		if HostRequestExecution.limit_nanoseconds!(nanoseconds) { Ok({}) } else { Err(Unavailable) }
}
