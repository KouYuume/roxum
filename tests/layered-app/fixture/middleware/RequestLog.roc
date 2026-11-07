import pf.Log
import pf.Middleware

## A presentation concern; it wraps the controller routes, not the use case.
RequestLog := [].{
	layer = [
		Middleware.Stage.BeforeBody(
			|_model, head| {
				Log.info!("request ${head.path}")
				Ok(head)
			},
		),
	]
}
