import "../../migrations/001_create_users.sql" as schema : Str
import pf.Secret
import pg.Postgres

Pool := [].{
	connect! = |settings| {
		password = Secret.from_file!(settings.password_file).map_err(|_| StartupErr("cannot read the database password file"))?
		Postgres.pool!(
			Postgres.Config.{
				host: settings.host,
				port: settings.port,
				user: settings.user,
				database: settings.name,
				password: Postgres.Password.Secret(password),
			},
		).map_err(|_| StartupErr("invalid database settings"))
	}
	migrate! = |db| {
		_ = Postgres.execute!(db, schema, [])?
		Ok({})
	}
}
