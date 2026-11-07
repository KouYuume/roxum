import Product

## The domain's repository port. A concrete adapter supplies the operations
## a use case calls; `Unavailable` covers storage failures the domain cannot
## act on.
ProductRepository := [].{
	find! : repository, Str => Try(Product, [NotFound, Unavailable])
		where [repository.find! : repository, Str => Try(Product, [NotFound, Unavailable])]
	find! = |repository, sku| repository.find!(sku)

	## Stores a new product; `AlreadyExists` when its SKU is taken.
	add! : repository, Product => Try({}, [AlreadyExists, Unavailable])
		where [repository.add! : repository, Product => Try({}, [AlreadyExists, Unavailable])]
	add! = |repository, product| repository.add!(product)

	## Replaces the stored product with the same SKU.
	save! : repository, Product => Try({}, [NotFound, Unavailable])
		where [repository.save! : repository, Product => Try({}, [NotFound, Unavailable])]
	save! = |repository, product| repository.save!(product)

	remove! : repository, Str => Try({}, [NotFound, Unavailable])
		where [repository.remove! : repository, Str => Try({}, [NotFound, Unavailable])]
	remove! = |repository, sku| repository.remove!(sku)
}
