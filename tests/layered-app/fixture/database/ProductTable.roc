import pg.Postgres

## The `products` table and its sample rows. `init!` runs this in every
## worker, so each statement is idempotent.
ProductTable := [].{
	migrate! : Postgres.Pool => Try({}, [MigrationFailed])
	migrate! = |db| {
		statements = [
			"CREATE TABLE IF NOT EXISTS products (sku TEXT PRIMARY KEY, name TEXT NOT NULL, unit_price_cents BIGINT NOT NULL CHECK (unit_price_cents >= 0))",
			"INSERT INTO products (sku, name, unit_price_cents) VALUES ('tea', 'Green tea', 450), ('mug', 'Stoneware mug', 1200) ON CONFLICT (sku) DO NOTHING",
		]
		for statement in statements {
			match Postgres.execute!(db, statement, []) {
				Ok(_) => {}
				Err(_) => return Err(MigrationFailed)
			}
		}
		Ok({})
	}
}
