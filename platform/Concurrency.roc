import HostConcurrency

## How many requests hold a key at once, kept by the host. What to limit, and what
## to answer, is up to Roc code such as `roxum-concurrency-limit`.
##
## Make a limiter in `init!` and keep it in the model. Every thread of a process
## shares it. Each process has its own, so with `processes: 4` a key is held
## separately in each of the four.
##
## The memory for `max_keys` keys is reserved when the limiter is made, at most 96
## bytes a key, and touched only as keys arrive. A key itself is not kept, only a
## keyed 128-bit hash of it.
Concurrency :: U64.{
	## A limiter that holds at most `max_keys` keys at once, 1 to 268,435,456.
	new! : { max_keys : U64 } => Try(Concurrency, [InvalidConcurrency, ConcurrencyTableFull, ConcurrencyFailed])
	new! = |settings|
		match HostConcurrency.new!(settings.max_keys) {
			Made(handle) => Ok(Concurrency.(handle))
			Invalid => Err(InvalidConcurrency)
			TableFull => Err(ConcurrencyTableFull)
			Failed => Err(ConcurrencyFailed)
		}

	## Holds the key for this request, unless `limit` requests already hold it
	## (`Err(AtLimit)`). The host gives it back when the request ends, whether the
	## response was sent, the client went away, or the handler crashed; a streamed
	## body holds it until the body ends. There is no way to give it back sooner.
	##
	## A new key does not fit when the limiter already holds `max_keys` keys
	## (`Err(Full)`). A key leaves when its last holder ends. A request holds at most
	## 8 keys, and only a request can hold one: past that, or in `init!`, this crashes.
	acquire! : Concurrency, Str, U64 => Try({}, [AtLimit, Full])
	acquire! = |Concurrency.(handle), key, limit|
		match HostConcurrency.acquire!(handle, key, limit) {
			Acquired => Ok({})
			AtLimit => Err(AtLimit)
			Full => Err(Full)
			TooMany => crash "Concurrency: a request holds at most 8 keys"
			OutsideRequest => crash "Concurrency: only a request can hold a key, and init! is not one"
			Unknown => crash "Concurrency: a limiter's handle lasts as long as its process"
		}
}
