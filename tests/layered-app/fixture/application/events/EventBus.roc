import ../../domain/product/ProductEvent

## Publishing is the effectful boundary for a domain event.
EventBus := [].{
	publish! : bus, ProductEvent => {}
		where [bus.publish! : bus, ProductEvent => {}]
	publish! = |bus, event| bus.publish!(event)
}
