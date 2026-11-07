import User
import ../../errors/InfrastructureError

UserRepository := [].{
	Save : User => Try({}, InfrastructureError)
	Find : Str => Try(Try(User, [Missing]), InfrastructureError)
}
