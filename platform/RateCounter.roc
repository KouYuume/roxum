import HostRateCounter

## Counts for rate limits, kept by the host: how many times each key was counted
## in this window of time and the one before it. How to use the counts, and what
## to answer, is up to Roc code such as `roxum-rate-limit`.
##
## Make a counter in `init!` and keep it in the model. Every thread of a process
## shares it. Each process has its own, so with `processes: 4` a key is counted
## separately in each of the four, and a restart starts from nothing.
##
## The memory for `max_keys` keys is reserved when the counter is made, at most 192
## bytes a key, and touched only as keys arrive. A key itself is not kept, only a
## keyed 128-bit hash of it.
RateCounter :: { handle : U64, window_ms : U64 }.{
	## A key's counts. `elapsed_ms` says how far this window has gone, of
	## `window_ms`.
	Counts : { current : U64, previous : U64, elapsed_ms : U64, window_ms : U64 }

	## A counter with this window and this many keys in a window. `window_seconds`
	## is 1 to 31,536,000 (a year); `max_keys` is 1 to 268,435,456.
	new! : { window_seconds : U64, max_keys : U64 } => Try(RateCounter, [InvalidRateCounter, RateCounterTableFull, RateCounterFailed])
	new! = |settings|
		match HostRateCounter.new!(settings.window_seconds, settings.max_keys) {
			Made(handle) => Ok({ handle, window_ms: settings.window_seconds * 1000 })
			Invalid => Err(InvalidRateCounter)
			TableFull => Err(RateCounterTableFull)
			Failed => Err(RateCounterFailed)
		}

	## Adds `amount` to the key and returns its counts, this addition included.
	##
	## When the window already has `max_keys` keys, a new key is not recorded or
	## counted, and no key is pushed out: the result is `Err(Full)`. A key already in
	## this window goes on counting. The window's keys end with it, so a full counter
	## opens again with the next window.
	add! : RateCounter, Str, U64 => Try(RateCounter.Counts, [Full])
	add! = |counter, key, amount|
		match HostRateCounter.add!(counter.handle, key, amount) {
			Counted(counts) => Ok({ current: counts.current, previous: counts.previous, elapsed_ms: counts.elapsed_ms, window_ms: counter.window_ms })
			Full => Err(Full)
			Unknown => crash "RateCounter: a counter's handle lasts as long as its process"
		}

	## The key's counts, without counting or recording it: for a limit that counts
	## only failures, read before trying and `add!` after failing.
	counts! : RateCounter, Str => RateCounter.Counts
	counts! = |counter, key|
		match RateCounter.add!(counter, key, 0) {
			Ok(counts) => counts
			Err(Full) => crash "RateCounter: adding nothing does not record a key"
		}
}
