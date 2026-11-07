import ../../domain/user/User
import ../../domain/user/UserRepository
import ../../errors/ApplicationError

GetUser := [].{
	execute! : UserRepository.Find, Str => Try(User.Data, ApplicationError)
	execute! = |find!, id| {
		match find!(id).map_err(ApplicationError.from_infrastructure)? {
			Ok(user) => Ok(User.to_data(user))
			Err(Missing) => Err(ApplicationError.EntityNotFound(id))
		}
	}
}
