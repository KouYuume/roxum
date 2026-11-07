## A read-model port, separate from the domain repository used by commands.
ProductQueryService := [].{
	get! : service, Str => Try({ sku : Str, name : Str, unit_price_cents : U64 }, [NotFound, Unavailable])
		where [service.get! : service, Str => Try({ sku : Str, name : Str, unit_price_cents : U64 }, [NotFound, Unavailable])]
	get! = |service, sku| service.get!(sku)
}
