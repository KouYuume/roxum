import ../domain/product/Product
import pf.Log
import pg.Postgres

## The repository adapter implements the operations of the domain port on
## the `products` table. Database failures become `Unavailable`; the details
## go to the log, never to the client.
ProductRepositoryImpl := { db : Postgres.Pool }.{
	new : Postgres.Pool -> ProductRepositoryImpl
	new = |db| { db: db }

	find! : ProductRepositoryImpl, Str => Try(Product, [NotFound, Unavailable])
	find! = |repository, sku| {
		rows : Try(List({ sku : Str, name : Str, unit_price_cents : U64 }), _)
		rows = Postgres.query!(repository.db, "SELECT sku, name, unit_price_cents FROM products WHERE sku = $1", [Postgres.Param.Text(sku)])
		match rows {
			Ok([row]) => Ok(Product.new(row.sku, row.name, row.unit_price_cents))
			Ok(_) => Err(NotFound)
			Err(_) => {
				Log.error!("products: the product query failed")
				Err(Unavailable)
			}
		}
	}

	add! : ProductRepositoryImpl, Product => Try({}, [AlreadyExists, Unavailable])
	add! = |repository, product| {
		inserted = Postgres.execute!(
			repository.db,
			"INSERT INTO products (sku, name, unit_price_cents) VALUES ($1, $2, $3)",
			[Postgres.Param.Text(Product.sku(product)), Postgres.Param.Text(Product.name(product)), price_param(product)],
		)
		match inserted {
			Ok(_) => Ok({})
			# SQLSTATE 23505: the SKU, the primary key, is taken.
			Err(PostgresQueryFailed({ code: "23505", .. })) => Err(AlreadyExists)
			Err(_) => {
				Log.error!("products: the insert failed")
				Err(Unavailable)
			}
		}
	}

	save! : ProductRepositoryImpl, Product => Try({}, [NotFound, Unavailable])
	save! = |repository, product| {
		updated = Postgres.execute!(
			repository.db,
			"UPDATE products SET name = $2, unit_price_cents = $3 WHERE sku = $1",
			[Postgres.Param.Text(Product.sku(product)), Postgres.Param.Text(Product.name(product)), price_param(product)],
		)
		changed!(updated, "update")
	}

	remove! : ProductRepositoryImpl, Str => Try({}, [NotFound, Unavailable])
	remove! = |repository, sku| {
		deleted = Postgres.execute!(repository.db, "DELETE FROM products WHERE sku = $1", [Postgres.Param.Text(sku)])
		changed!(deleted, "delete")
	}
}

## A product's price fits a BIGINT: the domain caps it at 10,000,000.
price_param : Product -> Postgres.Param
price_param = |product| Postgres.Param.Int(U64.to_i64_wrap(Product.unit_price_cents(product)))

## The outcome of an update or a delete by SKU: no row changed means no such
## product.
changed! = |result, operation|
	match result {
		Ok(0) => Err(NotFound)
		Ok(_) => Ok({})
		Err(_) => {
			Log.error!("products: the ${operation} failed")
			Err(Unavailable)
		}
	}
