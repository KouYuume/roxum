import ../../domain/product/Product
import ../../domain/product/ProductEvent
import ../../domain/product/ProductRepository
import ../events/EventBus

## Loads through the domain repository, asks the domain to decide, then
## publishes the resulting event. Adapters are supplied by the caller.
QuoteProduct := [].{
	run! : repository, tax_api, event_bus, Str, U64 => Try({ name : Str, subtotal_cents : U64, tax_cents : U64, total_cents : U64 }, [NotFound, Unavailable, InvalidQuantity, TooMany])
		where [repository.find! : repository, Str => Try(Product, [NotFound, Unavailable]), tax_api.rate! : tax_api => Try(U64, [Unavailable]), event_bus.publish! : event_bus, ProductEvent => {}]
	run! = |repository, tax_api, event_bus, sku, quantity| {
		product = match ProductRepository.find!(repository, sku) {
			Ok(found) => found
			Err(NotFound) => return Err(NotFound)
			Err(Unavailable) => return Err(Unavailable)
		}
		rate = match tax_api.rate!() {
			Ok(percent) => percent
			Err(Unavailable) => return Err(Unavailable)
		}
		quote = match Product.quote(product, quantity, rate) {
			Ok(priced) => priced
			Err(InvalidQuantity) => return Err(InvalidQuantity)
			Err(TooMany) => return Err(TooMany)
		}
		EventBus.publish!(event_bus, quote.event)
		Ok({
			name: Product.name(product),
			subtotal_cents: quote.subtotal_cents,
			tax_cents: quote.tax_cents,
			total_cents: quote.total_cents,
		})
	}
}
