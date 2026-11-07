import ../../../core/domain/user/User
import ../../../core/query_services/users/SearchUsersQueryService
import ../../../core/errors/InfrastructureError
import pg.Postgres

UserSearchImpl := [].{
	search! : Postgres.Pool, SearchUsersQueryService.Query => Try(List(User.Data), InfrastructureError)
	search! = |db, query| {
		{ sql, params } = match (query.name, query.email) {
			(Ok(name), Ok(email)) => { sql: "SELECT id::text AS id, name, email FROM users WHERE name = $1 AND email = $2 ORDER BY id", params: [Postgres.Param.Text(name), Postgres.Param.Text(email)] }
			(Ok(name), Err(Missing)) => { sql: "SELECT id::text AS id, name, email FROM users WHERE name = $1 ORDER BY id", params: [Postgres.Param.Text(name)] }
			(Err(Missing), Ok(email)) => { sql: "SELECT id::text AS id, name, email FROM users WHERE email = $1 ORDER BY id", params: [Postgres.Param.Text(email)] }
			(Err(Missing), Err(Missing)) => return Err(InfrastructureError.DatabaseError)
		}
		Postgres.query!(db, sql, params).map_err(|_| InfrastructureError.DatabaseError)
	}
}
