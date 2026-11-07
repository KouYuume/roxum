import pf.Log

## Example external-event sink; replace logging with a real broker adapter.
ExternalEventHandler := {}.{
	sample : ExternalEventHandler
	sample = {}

	handle! : ExternalEventHandler, Str => {}
	handle! = |_, message| Log.info!(message)
}
