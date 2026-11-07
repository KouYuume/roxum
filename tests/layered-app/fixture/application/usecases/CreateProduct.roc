import ../../domain/product/Product
import ../../domain/product/ProductRepository

## Lets the domain decide whether the product is valid, then stores it.
CreateProduct := [].{
	run! : repository, Str, Str, U64 => Try(Product, [InvalidSku, InvalidName, InvalidPrice, AlreadyExists, Unavailable])
		where [repository.add! : repository, Product => Try({}, [AlreadyExists, Unavailable])]
	run! = |repository, sku, name, unit_price_cents| {
		product = Product.create(sku, name, unit_price_cents)?
		ProductRepository.add!(repository, product)?
		Ok(product)
	}
}
