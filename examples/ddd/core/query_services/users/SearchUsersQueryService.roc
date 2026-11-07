import ../../domain/user/User
import ../../errors/InfrastructureError

SearchUsersQueryService := [].{
	Query : { name : Try(Str, [Missing]), email : Try(Str, [Missing]) }
	Search : SearchUsersQueryService.Query => Try(List(User.Data), InfrastructureError)
}
