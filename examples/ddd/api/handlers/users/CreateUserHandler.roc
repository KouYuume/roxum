import ../../AppState
import ../../HandlerError
import ../../../core/usecases/users/CreateUser
import pf.Extract
import pf.Reply

CreateUserHandler := [].{
	handle! : AppState, { body : [Ok(Extract.JsonBody(CreateUser.Params)), Err(Reply)] } => Try(Reply, Reply)
	handle! = |AppState.({ save_user!, next_user_id!, .. }), { body }| {
		request = match body {
			Ok(Extract.JsonBody.(value)) => value
			Err(_) => return Err(HandlerError.invalid_request({}))
		}
		result = CreateUser.execute!(save_user!, next_user_id!, request).map_err(HandlerError.from_application)?
		Ok(Reply.json(result))
	}
}
