## An event produced by a domain decision. Publishing it belongs to the
## application layer; creating it is pure.
ProductEvent := [Quoted({ sku : Str, quantity : U64, total_cents : U64 })].{
	quoted : Str, U64, U64 -> ProductEvent
	quoted = |sku, quantity, total_cents| Quoted({ sku, quantity, total_cents })
}
