import pf.HeaderName
import pf.HeaderValue
import pf.IpAddr
import pf.Middleware
import pf.RateCounter
import pf.Reply
import pf.RequestHead
import pf.ResponseHeader

## Rate limits on the counts of a `RateCounter`. A route says its limit with a tag
## of the app's, and a layer turns the tag into a check:
##
## ```roc
## Router.route("/search", MethodRouter.get(search).tags([Limit(100)]))
##     .layer(RateLimit.layer(|model, head, tag|
##         match tag {
##             Limit(limit) => Ok(RateLimit.Check.{
##                 counter: model.per_minute,
##                 key: match head.remote_addr { Tcp({ ip, .. }) => "search:${RateLimit.client_ip(ip)}", Unix => "search:unix" },
##                 limit,
##                 on_full: RateLimit.OnFull.Allow,
##             })
##             _ => Err(NoLimit)
##         }))
## ```
RateLimit := [].{
	## What to do when the counter already has every key it may hold, and this
	## request's key is new. `Allow` lets it through uncounted; `Reject` answers 429.
	OnFull := [Allow, Reject]

	## One limit on one key: at most `limit` in about a window of the counter. The
	## key says what is counted, so a limit that counts apart from another on the
	## same counter gives its keys a prefix of its own.
	Check := { counter : RateCounter, key : Str, limit : U64, on_full : RateLimit.OnFull }

	## A layer that runs, before the body is received, the check that `check_for`
	## makes of each tag of the route. A request that goes over a limit is answered
	## 429 with `Retry-After`. Write it after a layer that `check_for` reads
	## `head.provided` from. A request that goes over one check has still been
	## counted by the checks before it.
	layer : (model, RequestHead(tag, provided), tag -> Try(RateLimit.Check, [NoLimit])) -> List(Middleware.Stage(model, tag, provided))
	layer = |check_for| [
		Middleware.Stage.BeforeBody(
			|model, head| {
				for tag in head.tags {
					match check_for(model, head, tag) {
						Ok(check) => RateLimit.check!(check)?
						Err(NoLimit) => {}
					}
				}
				Ok(head)
			},
		),
	]

	## Counts one against the key, and answers 429 when that goes over the limit.
	check! : RateLimit.Check => Try({}, Reply)
	check! = |check|
		match RateCounter.add!(check.counter, check.key, 1) {
			Ok(counts) if estimate(counts) > check.limit => Err(too_many(counts))
			Ok(_) => Ok({})
			Err(Full) =>
				match check.on_full {
					Allow => Ok({})
					Reject => Err(too_many(RateCounter.counts!(check.counter, check.key)))
				}
		}

	## Answers 429 when the key has reached the limit, without counting: for a limit
	## on failures, such as wrong passwords. Call this before trying, and
	## `RateCounter.add!` after failing.
	peek! : RateLimit.Check => Try({}, Reply)
	peek! = |check| {
		counts = RateCounter.counts!(check.counter, check.key)
		if estimate(counts) >= check.limit {
			Err(too_many(counts))
		} else {
			Ok({})
		}
	}

	## The client's address as a key. An IPv6 client usually holds a whole `/64`, so
	## this gives only that much of the address. Behind a proxy, use
	## `roxum-proxy-headers` first, or every client is the proxy.
	client_ip : IpAddr -> Str
	client_ip = |ip|
		match ip {
			V4((a, b, c, d)) => "${a.to_str()}.${b.to_str()}.${c.to_str()}.${d.to_str()}"
			V6((a, b, c, d, _, _, _, _)) => "${a.to_str()}:${b.to_str()}:${c.to_str()}:${d.to_str()}::/64"
		}
}

# The count over the window that ended just now: all of this window's, and of the
# window before, the part that is still inside. A count takes 32 bits and a window
# 35, so the product needs more than 64.
estimate : RateCounter.Counts -> U64
estimate = |counts| {
	remaining = counts.window_ms - counts.elapsed_ms
	weighted = counts.previous.to_u128() * remaining.to_u128() / counts.window_ms.to_u128()
	weighted.to_u64_wrap() + counts.current
}

# The earliest the client could be let in: the counts change no sooner than the
# window's end.
too_many : RateCounter.Counts -> Reply
too_many = |counts| {
	seconds = (counts.window_ms - counts.elapsed_ms + 999) / 1000
	match HeaderValue.from_str(seconds.to_str()) {
		Ok(value) => Reply.status(429).with_headers([ResponseHeader.{ name: HeaderName.("retry-after"), value }])
		Err(_) => Reply.status(429)
	}
}

counts_at : U64, U64, U64 -> RateCounter.Counts
counts_at = |current, previous, elapsed_ms| { current, previous, elapsed_ms, window_ms: 60000 }

# The window before weighs what is left of this one: all at its start, half at the
# middle, nothing at the end.
expect estimate(counts_at(1, 10, 0)) == 11
expect estimate(counts_at(1, 10, 30000)) == 6
expect estimate(counts_at(1, 10, 59999)) == 1

# The largest counts in the longest window do not overflow.
expect estimate({ current: 4294967295, previous: 4294967295, elapsed_ms: 0, window_ms: 31536000000 }) == 8589934590

# IPv4 whole; IPv6 to its /64, so that addresses in one /64 are one key.
expect RateLimit.client_ip(V4((192, 0, 2, 1))) == "192.0.2.1"
expect RateLimit.client_ip(V6((8193, 3512, 0, 1, 2, 3, 4, 5))) == RateLimit.client_ip(V6((8193, 3512, 0, 1, 9, 9, 9, 9)))
expect RateLimit.client_ip(V6((8193, 3512, 0, 1, 0, 0, 0, 0))) != RateLimit.client_ip(V6((8193, 3512, 0, 2, 0, 0, 0, 0)))
