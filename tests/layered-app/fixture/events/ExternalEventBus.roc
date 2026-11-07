import ../application/events/ProductQuotedHandler
import ../domain/product/ProductEvent
import ExternalEventHandler

## Implements the application event-bus port by handing each event to the
## application handler, which formats an outbound message for the sink.
ExternalEventBus := { handler : ExternalEventHandler }.{
	sample : ExternalEventBus
	sample = { handler: ExternalEventHandler.sample }

	publish! : ExternalEventBus, ProductEvent => {}
	publish! = |bus, event| ProductQuotedHandler.handle!(bus.handler, event)
}
