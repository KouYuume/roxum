import ../../core/domain/user/User
import ../../core/errors/InfrastructureError
import pg.Postgres

UserRepositoryImpl := [].{

	save! : Postgres.Pool, User => Try({}, InfrastructureError)
	save! = |db, user| {
		_ = Postgres.execute!(db, "INSERT INTO users (id, name, email) VALUES ($1::uuid, $2, $3) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email", [Postgres.Param.Text(User.id(user)), Postgres.Param.Text(User.name(user)), Postgres.Param.Text(User.email(user))]).map_err(|_| InfrastructureError.DatabaseError)?
		Ok({})
	}

	find! : Postgres.Pool, Str => Try(Try(User, [Missing]), InfrastructureError)
	find! = |db, id| {
		rows : Try(List({ id : Str, name : Str, email : Str }), _)
		rows = Postgres.query!(db, "SELECT id::text AS id, name, email FROM users WHERE id = $1::uuid", [Postgres.Param.Text(id)])
		match rows.map_err(|_| InfrastructureError.DatabaseError)? {
			[row] => Ok(Ok(User.new(row.id, row.name, row.email).map_err(|_| InfrastructureError.DatabaseError)?))
			[] => Ok(Err(Missing))
			_ => Err(InfrastructureError.DatabaseError)
		}
	}
}
