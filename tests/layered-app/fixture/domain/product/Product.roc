import ProductEvent

## A product and its pure pricing rule. Quantity is limited to 1–10 for this
## example, making both API boundaries and arithmetic easy to inspect.
Product := { sku : Str, name : Str, unit_price_cents : U64 }.{
	new : Str, Str, U64 -> Product
	new = |sku, name, unit_price_cents| { sku, name, unit_price_cents }

	quote : Product, U64, U64 -> Try({ subtotal_cents : U64, tax_cents : U64, total_cents : U64, event : ProductEvent }, [InvalidQuantity, TooMany])
	quote = |product, quantity, tax_percent| {
		if quantity == 0 { return Err(InvalidQuantity) }
		if quantity > 10 { return Err(TooMany) }
		subtotal_cents = product.unit_price_cents * quantity
		tax_cents = subtotal_cents * tax_percent // 100
		total_cents = subtotal_cents + tax_cents
		Ok({
			subtotal_cents,
			tax_cents,
			total_cents,
			event: ProductEvent.quoted(product.sku, quantity, total_cents),
		})
	}

	name : Product -> Str
	name = |product| product.name

	## A product as the catalog accepts it. The SKU is 1–32 lowercase ASCII
	## letters, digits, or `-`, so it can stand in a path and a `Location`
	## field as it is; the name is 1–100 bytes; the price is at most
	## 10,000,000 cents.
	create : Str, Str, U64 -> Try(Product, [InvalidSku, InvalidName, InvalidPrice])
	create = |given_sku, given_name, given_price_cents| {
		if !valid_sku(given_sku) { return Err(InvalidSku) }
		name_bytes = Str.count_utf8_bytes(given_name)
		if name_bytes == 0 or name_bytes > 100 { return Err(InvalidName) }
		if given_price_cents > maximum_price_cents { return Err(InvalidPrice) }
		Ok(Product.new(given_sku, given_name, given_price_cents))
	}

	sku : Product -> Str
	sku = |product| product.sku

	unit_price_cents : Product -> U64
	unit_price_cents = |product| product.unit_price_cents
}

maximum_price_cents : U64
maximum_price_cents = 10_000_000

valid_sku : Str -> Bool
valid_sku = |sku| {
	bytes = sku.to_utf8()
	length = List.len(bytes)
	length >= 1 and length <= 32 and List.all(bytes, |byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-')
}

sample = Product.new("tea", "Green tea", 450)
# The accepted quantity interval is 1–10. Test its immediate outside values
# and the nearest valid values on either side of each boundary.
expect match Product.quote(sample, 0, 10) {
	Err(InvalidQuantity) => Bool.True
	_ => Bool.False
}
expect match Product.quote(sample, 1, 10) {
	Ok(quote) => quote.total_cents == 495
	_ => Bool.False
}
expect match Product.quote(sample, 2, 10) {
	Ok(quote) => quote.total_cents == 990
	_ => Bool.False
}
expect match Product.quote(sample, 9, 10) {
	Ok(quote) => quote.total_cents == 4455
	_ => Bool.False
}
expect match Product.quote(sample, 10, 10) {
	Ok(quote) => quote.total_cents == 4950
	_ => Bool.False
}
expect match Product.quote(sample, 11, 10) {
	Err(TooMany) => Bool.True
	_ => Bool.False
}

created = |given_sku, given_name, price|
	match Product.create(given_sku, given_name, price) {
		Ok(_) => Ok({})
		Err(error) => Err(error)
	}

# SKU length 1–32: 0 and 33 are rejected, 1 and 32 kept. Bytes: the edges of
# each accepted range are kept; an uppercase letter and `/` are not.
expect created("", "Tea", 1) == Err(InvalidSku)
expect created("a", "Tea", 1) == Ok({})
expect created(Str.repeat("a", 32), "Tea", 1) == Ok({})
expect created(Str.repeat("a", 33), "Tea", 1) == Err(InvalidSku)
expect created("az09-", "Tea", 1) == Ok({})
expect created("Tea", "Tea", 1) == Err(InvalidSku)
expect created("a/b", "Tea", 1) == Err(InvalidSku)

# Name length 1–100 bytes, counted in UTF-8: a two-byte character at the limit.
expect created("tea", "", 1) == Err(InvalidName)
expect created("tea", "T", 1) == Ok({})
expect created("tea", Str.repeat("a", 100), 1) == Ok({})
expect created("tea", Str.repeat("a", 101), 1) == Err(InvalidName)
expect created("tea", Str.concat(Str.repeat("a", 98), "é"), 1) == Ok({})
expect created("tea", Str.concat(Str.repeat("a", 99), "é"), 1) == Err(InvalidName)

# Price 0–10,000,000 cents.
expect created("tea", "Tea", 0) == Ok({})
expect created("tea", "Tea", 9_999_999) == Ok({})
expect created("tea", "Tea", 10_000_000) == Ok({})
expect created("tea", "Tea", 10_000_001) == Err(InvalidPrice)
