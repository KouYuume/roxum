import ../core/domain/user/User
import pf.Log

UserWithEffect := [].{
	make : Str -> User
	make = |id| {
		Log.info!("creating user")
		User.new({ id, name: "Alice", email: "alice@example.com" }) ?? crash "valid fixture email"
	}
}
