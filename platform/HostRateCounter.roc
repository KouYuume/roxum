HostRateCounter := [].{
	## The result of making a counter.
	##
	## - `Made`: the handle of the counter, which the host keeps.
	## - `Invalid`: a window or key limit out of range.
	## - `TableFull`: the process already holds 64 counters.
	## - `Failed`: the memory for the keys could not be reserved.
	Made := [Made(U64), Invalid, TableFull, Failed]

	## The result of counting.
	##
	## - `Counted`: the key's counts in this window and the one before it, and
	##   how far this window has gone.
	## - `Full`: the key is new and the window already has every key it may hold.
	## - `Unknown`: no counter has the handle.
	Counted := [Counted({ current : U64, previous : U64, elapsed_ms : U64 }), Full, Unknown]

	new! : U64, U64 => HostRateCounter.Made
	add! : U64, Str, U64 => HostRateCounter.Counted
}
