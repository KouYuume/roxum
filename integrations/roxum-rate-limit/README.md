# roxum-rate-limit

`roxum-rate-limit` answers `429` past a limit, on the counts of the platform's `RateCounter`. It is optional. A route says
its limit with a tag of the app's, and a layer turns the tag into a check:

```roc
Tag : [Limit(U64)]

routes =
	Router.new
		.route("/search", MethodRouter.get(search).tags([Limit(100)]))
		.layer(RateLimit.layer(|model, head, tag|
			match tag {
				Limit(limit) => Ok(RateLimit.Check.{
					counter: model.per_minute,
					key: match head.remote_addr {
						Tcp({ ip, .. }) => "search:${RateLimit.client_ip(ip)}"
						Unix => "search:unix"
					},
					limit,
					on_full: RateLimit.OnFull.Allow,
				})
			}))
```

The counter is made in `init!` and kept in the model:

```roc
per_minute = RateCounter.new!({ window_seconds: 60, max_keys: 100000 })?
```

`limit` applies over about a window: this window's count, plus the window before weighted by what is left of this one.

## Limits only an app can count

The key and the moment to count are the app's, so a limit can use what a proxy cannot see. For wrong passwords per user,
read before trying and count after failing:

```roc
check = RateLimit.Check.{ counter: model.logins, key: user.id, limit: 5, on_full: RateLimit.OnFull.Reject }
RateLimit.peek!(check)?
if password_matches {
	...
} else {
	_ = RateCounter.add!(check.counter, check.key, 1)
	...
}
```

## When the counter is full

A client can send as many keys as it likes, so keep them from reaching the counter: limit by address first, and count by
user name only for users that exist. An attacker with many addresses can still fill it. Then a new key is not recorded,
and no key is pushed out, so what has been counted cannot be reset by filling the counter. `on_full` says what such a
request gets: `Allow` lets it through uncounted, and `Reject` answers 429. Keys already in the window go on counting. The
window's keys end with it, so the counter opens again when the attack stops.

## What is counted where

Each process has its own counts, and a restart starts from nothing. All threads of a process share them. With the default
of one process that is the whole instance; with several instances, or with `processes` above 1, the limit applies to
each process. For a limit across instances, keep the counts in a shared store.

Unix peers have no IP address. The `unix` key above shares one limit across them; use an authenticated application identity when per-client limits are needed.
