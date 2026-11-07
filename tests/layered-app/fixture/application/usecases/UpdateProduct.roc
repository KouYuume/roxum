import ../../domain/product/Product
import ../../domain/product/ProductRepository

## Replaces a product's name and price. The domain checks the new values as
## for a new product; the SKU stays.
UpdateProduct := [].{
	run! : repository, Str, Str, U64 => Try(Product, [InvalidSku, InvalidName, InvalidPrice, NotFound, Unavailable])
		where [repository.save! : repository, Product => Try({}, [NotFound, Unavailable])]
	run! = |repository, sku, name, unit_price_cents| {
		product = Product.create(sku, name, unit_price_cents)?
		ProductRepository.save!(repository, product)?
		Ok(product)
	}
}
