import HostRequestExecution
import Http

## Execution timing for the current HTTP/2 request. These effects are unavailable
## in `init!` and on HTTP/1. They carry no handle that can escape the request.
##
## Initial header completion is the immutable time origin. Body reception,
## queueing, and handler execution all count. `BeforeBody` middleware can set
## a deadline before waiting for input; ordinary handlers run after body EOF.
RequestExecution := [].{

	## Copies the input into an 8 MiB message heap before calling a pure decoder.
	## Returned values may retain that copy until request cleanup. Exhausted means
	## the host could not start the heap or copy the input. Allocation failure
	## inside the callback abandons the request under the Roc allocator contract.
	decode_bytes! : List(U8), (List(U8) -> value) => Try(value, [Unavailable, Exhausted])
	decode_bytes! = |bytes, decode|
		match HostRequestExecution.begin_decode!(bytes) {
			Input(owned) => {
				value = decode(owned)
				HostRequestExecution.end_decode!({})
				Ok(value)
			}
			Unavailable => Err(Unavailable)
			Exhausted => Err(Exhausted)
		}

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
	## Expiry cancels suspended I/O and resets the stream unless a response was
	## registered with `limit_with_response!` or `limit_with_trailers!`. Pure
	## computation is not preempted. Finite response commitment or streamed
	## terminal selection wins over later expiry; socket writes still have their
	## own timeout. This does not change idle/read/write timeouts.
	limit_nanoseconds! : U64 => Try({}, [Unavailable])
	limit_nanoseconds! = |nanoseconds|
		if HostRequestExecution.limit_nanoseconds!(nanoseconds) {
			Ok({})
		} else {
			Err(Unavailable)
		}

	## Tightens the same deadline and atomically installs a finite expiry response.
	## The host validates and copies the response before changing the deadline.
	## Invalid or oversized responses leave the previous configuration unchanged.
	## Repeated successful calls replace the response but never extend the deadline.
	## Expiry cancels execution and sends this response without running middleware.
	## Client cancellation, shutdown, and read/write timeouts do not use it.
	## Normal response commitment discards it. Delivery is best effort and bounded
	## by the connection's response limits, memory budget, and write timeout.
	limit_with_response! : U64, Http.Response => Try({}, [Unavailable, InvalidResponse])
	limit_with_response! = |nanoseconds, response|
		match HostRequestExecution.limit_with_response!(nanoseconds, response) {
			0 => Ok({})
			1 => Err(Unavailable)
			_ => Err(InvalidResponse)
		}

	## Registers terminal fields before starting HTTP/2 streamed output and
	## tightens the deadline from initial metadata. The host copies and validates
	## fields atomically. On expiry after headers, accepted DATA drains before
	## these trailers; before headers, expiry resets the request. A write timeout,
	## client cancellation or forced shutdown can prevent delivery. Normal finish
	## and expiry select their terminal exactly once. No abandoned code resumes.
	limit_with_trailers! : U64, List(Http.ResponseHeader) => Try({}, [Unavailable, InvalidTrailers, InvalidState])
	limit_with_trailers! = |nanoseconds, trailers|
		match HostRequestExecution.limit_with_trailers!(nanoseconds, trailers) {
			0 => Ok({})
			1 => Err(Unavailable)
			2 => Err(InvalidTrailers)
			_ => Err(InvalidState)
		}

}
