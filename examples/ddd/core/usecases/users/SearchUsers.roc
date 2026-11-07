import ../../domain/user/User
import ../../query_services/users/SearchUsersQueryService
import ../../errors/ApplicationError

SearchUsers := [].{
	execute! : SearchUsersQueryService.Search, SearchUsersQueryService.Query => Try(List(User.Data), ApplicationError)
	execute! = |search!, query| search!(query).map_err(ApplicationError.from_infrastructure)
}
