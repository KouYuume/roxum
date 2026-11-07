import ../../domain/user/User
import ../../domain/user/UserRepository
import ../../errors/ApplicationError

CreateUser := [].{
	Params : { name : Str, email : Str }
	execute! : UserRepository.Save, ({} => Str), CreateUser.Params => Try(User.Data, ApplicationError)
	execute! = |save!, next_id!, params| {
		user = User.new(next_id!({}), params.name, params.email).map_err(ApplicationError.from_domain)?
		save!(user).map_err(ApplicationError.from_infrastructure)?
		Ok(User.to_data(user))
	}
}
