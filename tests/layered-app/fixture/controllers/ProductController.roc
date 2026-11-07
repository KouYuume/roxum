import ../application/queries/ProductQueryService
import ../application/usecases/CreateProduct
import ../application/usecases/DeleteProduct
import ../application/usecases/QuoteProduct
import ../application/usecases/UpdateProduct
import ../domain/product/Product
import pf.Extract
import pf.HeaderName
import pf.HeaderValue
import pf.Reply
import pf.ResponseHeader
import pf.RouteContext

## The JSON body of `POST /products`. `parser_for` lets Roc derive the
## decoder; a body that does not fit is answered 400 before the use case runs.
NewProduct := { sku : Str, name : Str, price_cents : U64 }.{
	parser_for : _
}

## The JSON body of `PUT /products/{sku}`.
ProductChange := { name : Str, price_cents : U64 }.{
	parser_for : _
}

## HTTP input and output live here. Business decisions remain in the core.
ProductController := [].{
	show! = |model, context| {
		sku = path_param(context, "sku")
		match ProductQueryService.get!(model.query_service, sku) {
			Ok(view) => Ok(Reply.text("${view.sku}: ${view.name} (${view.unit_price_cents.to_str()} cents)\n"))
			Err(NotFound) => Err(Reply.text("product not found\n").with_status(404))
			Err(Unavailable) => Err(unavailable)
		}
	}

	quote! = |model, context| {
		sku = path_param(context, "sku")
		quantity = match U64.from_str(path_param(context, "quantity")) {
			Ok(value) => value
			Err(_) => return Err(Reply.text("quantity must be an integer from 1 to 10\n").with_status(400))
		}
		match QuoteProduct.run!(model.repository, model.tax_api, model.event_bus, sku, quantity) {
			Ok(quote) => Ok(Reply.text("${quote.name}: subtotal ${quote.subtotal_cents.to_str()}, tax ${quote.tax_cents.to_str()}, total ${quote.total_cents.to_str()} cents\n"))
			Err(NotFound) => Err(Reply.text("product not found\n").with_status(404))
			Err(Unavailable) => Err(unavailable)
			Err(InvalidQuantity) => Err(Reply.text("quantity must be an integer from 1 to 10\n").with_status(400))
			Err(TooMany) => Err(Reply.text("quantity must be an integer from 1 to 10\n").with_status(400))
		}
	}

	create! = |model, context| {
		body : NewProduct
		body = Extract.run!(Extract.json({}), context)?
		match CreateProduct.run!(model.repository, body.sku, body.name, body.price_cents) {
			Ok(product) => Ok(product_reply(product).with_status(201).with_headers([location(product)]))
			Err(AlreadyExists) => Err(Reply.text("a product with this SKU already exists\n").with_status(409))
			Err(InvalidSku) => Err(invalid_sku)
			Err(InvalidName) => Err(invalid_name)
			Err(InvalidPrice) => Err(invalid_price)
			Err(Unavailable) => Err(unavailable)
		}
	}

	update! = |model, context| {
		body : ProductChange
		body = Extract.run!(Extract.json({}), context)?
		match UpdateProduct.run!(model.repository, path_param(context, "sku"), body.name, body.price_cents) {
			Ok(product) => Ok(product_reply(product))
			Err(NotFound) => Err(not_found)
			Err(InvalidSku) => Err(not_found)
			Err(InvalidName) => Err(invalid_name)
			Err(InvalidPrice) => Err(invalid_price)
			Err(Unavailable) => Err(unavailable)
		}
	}

	delete! = |model, context|
		match DeleteProduct.run!(model.repository, path_param(context, "sku")) {
			Ok({}) => Ok(Reply.status(204))
			Err(NotFound) => Err(not_found)
			Err(Unavailable) => Err(unavailable)
		}
}

product_reply : Product -> Reply
product_reply = |product| Reply.text("${Product.sku(product)}: ${Product.name(product)} (${Product.unit_price_cents(product).to_str()} cents)\n")

## A valid SKU is lowercase letters, digits, and `-`, all valid in a field.
location : Product -> ResponseHeader
location = |product|
	match HeaderValue.from_str("/products/${Product.sku(product)}") {
		Ok(value) => ResponseHeader.{ name: HeaderName.("location"), value }
		Err(_) => crash "a valid SKU is a valid Location value"
	}

not_found : Reply
not_found = Reply.text("product not found\n").with_status(404)

invalid_sku : Reply
invalid_sku = Reply.text("sku must be 1 to 32 lowercase letters, digits, or -\n").with_status(400)

invalid_name : Reply
invalid_name = Reply.text("name must be 1 to 100 bytes\n").with_status(400)

invalid_price : Reply
invalid_price = Reply.text("price_cents must be at most 10000000\n").with_status(400)

## Storage is down: the client may try again later.
unavailable : Reply
unavailable = Reply.text("service unavailable\n").with_status(503)

path_param : RouteContext({}), Str -> Str
path_param = |context, name|
	match List.first(List.keep_if(context.path_params, |param| param.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
