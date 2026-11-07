import HostTime

## Reads the wall clock. Use `Instant` to measure elapsed time; the wall clock
## can jump when the system time is changed.
Time := [].{
	## A point in time as whole milliseconds since the Unix epoch
	## (1970-01-01T00:00:00Z). Negative values are before the epoch. It holds
	## no time zone. Date arithmetic, time zones, and formatting are left to
	## Roc libraries.
	Timestamp :: {
		unix_milliseconds : I64,
	}.{
		## Makes a timestamp from milliseconds since the Unix epoch.
		from_unix_milliseconds : I64 -> Timestamp
		from_unix_milliseconds = |milliseconds| { unix_milliseconds: milliseconds }

		## Returns the milliseconds since the Unix epoch.
		to_unix_milliseconds : Timestamp -> I64
		to_unix_milliseconds = |timestamp| timestamp.unix_milliseconds
	}

	## Returns the current wall-clock time (`CLOCK_REALTIME`), truncated to
	## milliseconds. If the clock cannot be read, the host stops the process
	## with a fatal error.
	now! : {} => Timestamp
	now! = |{}| Timestamp.from_unix_milliseconds(HostTime.now_unix_milliseconds!({}))
}
