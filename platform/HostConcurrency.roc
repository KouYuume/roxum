HostConcurrency := [].{
	## The result of making a limiter.
	##
	## - `Made`: the handle of the limiter, which the host keeps.
	## - `Invalid`: a key limit out of range.
	## - `TableFull`: the process already holds 64 limiters.
	## - `Failed`: the memory for the keys could not be reserved.
	Made := [Made(U64), Invalid, TableFull, Failed]

	## The result of acquiring.
	##
	## - `Acquired`: the request holds the key until it ends.
	## - `AtLimit`: the key's limit of requests already hold it.
	## - `Full`: the key is new and the limiter already holds every key it may.
	## - `TooMany`: the request already holds 8 keys.
	## - `OutsideRequest`: there is no request to hold it, as in `init!`.
	## - `Unknown`: no limiter has the handle.
	Acquired := [Acquired, AtLimit, Full, TooMany, OutsideRequest, Unknown]

	new! : U64 => HostConcurrency.Made
	acquire! : U64, Str, U64 => HostConcurrency.Acquired
}
