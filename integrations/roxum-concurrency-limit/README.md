# roxum-concurrency-limit

Limits how many requests hold a key at once: one route at five at a time, or one export at a time for each user. A proxy
can limit a path, but it cannot see a key only the app knows, such as the user.

```roc
import concurrency_limit.ConcurrencyLimit

# In init!, kept in the model:
limiter = Concurrency.new!({ max_keys: 100000 })?

# On the route:
MethodRouter.get(Handler.effectful(export!))
	.layer(ConcurrencyLimit.layer(|model, head|
		match head.provided.user {
			Ok(user) => Ok(ConcurrencyLimit.Check.{
				limiter: model.limiter,
				key: "export:${user.id}",
				limit: 1,
				on_full: ConcurrencyLimit.OnFull.Reject,
			})
			Err(_) => Err(NoLimit)
		}))
```

A request over the limit is answered `503` with `Retry-After: 1`, and does not wait: a waiting request would keep its
connection and its memory, and the process already refuses work this way when it is overloaded.

## What holds a key

- The key is held from the check until the request ends, a streamed body included.
- The host gives it back however the request ends: a response sent, a client gone away, or a handler crashed. Roc code cannot
  give it back early or forget to.
- A route with no such layer does no counting, and every other request behaves as before.

## Limits of a limiter

- Each process has its own limiter, so with `processes: 4` a limit of 5 allows 20. The default of one process has one.
- `max_keys` is how many keys are held at once. A key leaves when its last holder ends. When a new key does not fit, `on_full`
  says what happens: `Allow` lets the request through unlimited, `Reject` answers `503`. There is no default, because it is a
  choice between staying up and limiting.
- `Concurrency.new!` reserves at most 96 bytes for each key, touched only as keys arrive. A process holds up to 64 limiters.
- A request holds at most 8 keys; the ninth crashes the request, as a bug in the app.
