import pf.Log
import pg.Postgres

## A dedicated read adapter: controllers do not query the repository to
## assemble response views.
ProductQueryServiceImpl := { db : Postgres.Pool }.{
	new : Postgres.Pool -> ProductQueryServiceImpl
	new = |db| { db: db }

	get! : ProductQueryServiceImpl, Str => Try({ sku : Str, name : Str, unit_price_cents : U64 }, [NotFound, Unavailable])
	get! = |service, sku| {
		rows : Try(List({ sku : Str, name : Str, unit_price_cents : U64 }), _)
		rows = Postgres.query!(service.db, "SELECT sku, name, unit_price_cents FROM products WHERE sku = $1", [Postgres.Param.Text(sku)])
		match rows {
			Ok([view]) => Ok(view)
			Ok(_) => Err(NotFound)
			Err(_) => {
				Log.error!("products: the product view query failed")
				Err(Unavailable)
			}
		}
	}
}
