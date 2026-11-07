import ../../domain/product/ProductEvent

## Converts a domain event into a message for the outbound event adapter.
ProductQuotedHandler := [].{
	handle! : handler, ProductEvent => {}
		where [handler.handle! : handler, Str => {}]
	handle! = |handler, event|
		match event {
			Quoted({ sku, quantity, total_cents }) =>
				handler.handle!("product.quoted sku=${sku} quantity=${quantity.to_str()} total_cents=${total_cents.to_str()}")
		}
}
