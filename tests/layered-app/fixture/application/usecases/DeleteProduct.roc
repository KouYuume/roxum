import ../../domain/product/ProductRepository

DeleteProduct := [].{
	run! : repository, Str => Try({}, [NotFound, Unavailable])
		where [repository.remove! : repository, Str => Try({}, [NotFound, Unavailable])]
	run! = |repository, sku| ProductRepository.remove!(repository, sku)
}
