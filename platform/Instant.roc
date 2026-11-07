import HostInstant

## A reading of the monotonic clock, for measuring elapsed time within one
## process. The starting point is unspecified, so a value has no meaning
## outside the process that read it and cannot be converted to or from a
## `Time.Timestamp`.
Instant :: {
	nanoseconds : U64,
}.{
	## Reads the monotonic clock (`CLOCK_MONOTONIC`). If the clock cannot be read,
	## the host stops the process with a fatal error.
	now! : {} => Instant
	now! = |{}| { nanoseconds: HostInstant.now_nanoseconds!({}) }

	## The reading in nanoseconds from the clock's unspecified start. It
	## means something only next to other readings in the same process.
	to_nanoseconds : Instant -> U64
	to_nanoseconds = |instant| instant.nanoseconds

	## The reading `nanoseconds` from the clock's start: the inverse of
	## `to_nanoseconds`. For tests of code that takes an `Instant`, such as a
	## `RequestHead` built in Roc code.
	from_nanoseconds : U64 -> Instant
	from_nanoseconds = |nanoseconds| { nanoseconds: nanoseconds }

	## The reading `milliseconds` after `instant`, as a deadline for
	## `Sleep.until!`. Saturates at the clock's largest value.
	add_milliseconds : Instant, U64 -> Instant
	add_milliseconds = |instant, milliseconds|
		{ nanoseconds: instant.nanoseconds.plus_saturated(milliseconds.times_saturated(1_000_000)) }

	## Returns the nanoseconds from `start` to `end`. Returns 0 when `end` is
	## earlier than `start` instead of wrapping around.
	nanoseconds_between : Instant, Instant -> U64
	nanoseconds_between = |start, end|
		if end.nanoseconds >= start.nanoseconds {
			end.nanoseconds - start.nanoseconds
		} else {
			0
		}
}

# The monotonic clock should not move backwards; if it does, report an empty
# interval rather than wrapping the unsigned difference.
expect {
	start : Instant
	start = { nanoseconds: 10 }
	end : Instant
	end = { nanoseconds: 9 }
	Instant.nanoseconds_between(start, end) == 0
}

expect {
	start : Instant
	start = { nanoseconds: 10 }
	Instant.nanoseconds_between(start, start) == 0
}

expect {
	start : Instant
	start = { nanoseconds: 10 }
	end : Instant
	end = { nanoseconds: 11 }
	Instant.nanoseconds_between(start, end) == 1
}

expect {
	start : Instant
	start = { nanoseconds: 10 }
	Instant.add_milliseconds(start, 2).nanoseconds == 2_000_010
}

expect {
	start : Instant
	start = { nanoseconds: 10 }
	Instant.add_milliseconds(start, U64.highest).nanoseconds == U64.highest
}
