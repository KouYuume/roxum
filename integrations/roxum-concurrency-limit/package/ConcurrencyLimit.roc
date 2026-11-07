import pf.Concurrency
import pf.HeaderName
import pf.HeaderValue
import pf.Middleware
import pf.Reply
import pf.RequestHead
import pf.ResponseHeader

## Limits on how many requests hold a key at once, on a `Concurrency` limiter. A
## route says its limit with a layer of its own:
##
## ```roc
## MethodRouter.get(export)
##     .layer(ConcurrencyLimit.layer(|model, _head|
##         Ok(ConcurrencyLimit.Check.{
##             limiter: model.limiter,
##             key: "export",
##             limit: 5,
##             on_full: ConcurrencyLimit.OnFull.Reject,
##         })))
## ```
ConcurrencyLimit := [].{
	## What to do when the limiter already holds every key it may, and this request's
	## key is new. `Allow` lets it through unlimited; `Reject` answers 503.
	OnFull := [Allow, Reject]

	## One limit on one key: at most `limit` requests hold it at once. The key says
	## what is limited, so a limit that counts apart from another on the same limiter
	## gives its keys a prefix of its own.
	Check := { limiter : Concurrency, key : Str, limit : U64, on_full : ConcurrencyLimit.OnFull }

	## A layer that runs, before the body is received, the check that `check_for`
	## makes of each request. A request over the limit is answered 503 with
	## `Retry-After: 1` and does not wait. Write it after a layer that `check_for`
	## reads `head.provided` from.
	layer : (model, RequestHead(tag, provided) -> Try(ConcurrencyLimit.Check, [NoLimit])) -> List(Middleware.Stage(model, tag, provided))
	layer = |check_for| [
		Middleware.Stage.BeforeBody(
			|model, head|
				match check_for(model, head) {
					Ok(check) => {
						ConcurrencyLimit.check!(check)?
						Ok(head)
					}
					Err(NoLimit) => Ok(head)
				},
		),
	]

	## Holds the key for this request, and answers 503 when it cannot.
	check! : ConcurrencyLimit.Check => Try({}, Reply)
	check! = |check|
		match Concurrency.acquire!(check.limiter, check.key, check.limit) {
			Ok({}) => Ok({})
			Err(AtLimit) => Err(unavailable({}))
			Err(Full) =>
				match check.on_full {
					Allow => Ok({})
					Reject => Err(unavailable({}))
				}
		}
}

# The same answer as the host's when it is overloaded.
unavailable : {} -> Reply
unavailable = |{}| {
	retry_after : HeaderValue
	retry_after = "1"
	Reply.status(503).with_headers([ResponseHeader.{ name: HeaderName.("retry-after"), value: retry_after }])
}
