import AppState
import handlers/users/CreateUserHandler
import handlers/users/GetUserHandler
import handlers/users/SearchUsersHandler
import pf.Handler
import pf.MethodRouter
import pf.Router

Routes := [].{
	routes : Router(AppState, [], {})
	routes = Router.new
		.route("/users", MethodRouter.methods([
				MethodRouter.get(Handler.typed(SearchUsersHandler.handle!)),
				MethodRouter.post(Handler.typed(CreateUserHandler.handle!))
			]))
		.route("/users/{id}", MethodRouter.get(Handler.typed(GetUserHandler.handle!)))
}
