import ../../AppState
import ../../HandlerError
import ../../../core/usecases/users/GetUser
import pf.Extract
import pf.Reply

GetUserHandler := [].{
	handle! : AppState, { id : Extract.Path(Str) } => Try(Reply, Reply)
	handle! = |AppState.({ find_user!, .. }), { id: Extract.Path.(id) }| {
		result = GetUser.execute!(find_user!, id).map_err(HandlerError.from_application)?
		Ok(Reply.json(result))
	}
}
