import ../../AppState
import ../../HandlerError
import ../../../core/usecases/users/SearchUsers
import ../../../core/query_services/users/SearchUsersQueryService
import pf.Extract
import pf.Reply

SearchUsersHandler := [].{
	handle! : AppState, { query : [Ok(Extract.Query(SearchUsersQueryService.Query)), Err(Reply)] } => Try(Reply, Reply)
	handle! = |AppState.({ search_users!, .. }), { query }| {
		filters = match query {
			Ok(Extract.Query.(value)) => value
			Err(_) => return Err(HandlerError.invalid_request({}))
		}
		if filters.name == Err(Missing) and filters.email == Err(Missing) {
			return Err(HandlerError.invalid_request({}))
		}
		result = SearchUsers.execute!(search_users!, filters).map_err(HandlerError.from_application)?
		Ok(Reply.json(result))
	}
}
