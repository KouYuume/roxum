import HostSleep
import Instant

## Waiting for time to pass. In a handler the request waits and its thread
## serves other requests meanwhile; in `init!` the thread waits.
Sleep := [].{
	## Waits `milliseconds`. Repeated, the time between wakes grows by the
	## time the work in between takes; `until!` keeps a fixed interval.
	millis! : U64 => {}
	millis! = |milliseconds| HostSleep.milliseconds!(milliseconds)

	## Waits until the monotonic clock reaches `deadline`; returns at once when
	## it already has. To act every second without drift, add the interval to
	## the previous deadline rather than to `Instant.now!`:
	##
	## ```roc
	## next = Instant.add_milliseconds(previous, 1_000)
	## Sleep.until!(next)
	## ```
	until! : Instant => {}
	until! = |deadline| HostSleep.until_nanoseconds!(Instant.to_nanoseconds(deadline))
}
