import AppState
import CurrentUser
import Provided
import pf.Extract
import pf.Reply
import pf.RouteContext

## The handlers check no access: the routes' tags and the layers did.
Handlers := [].{
	list_shared : AppState, RouteContext(Provided) -> Try(Reply, Reply)
	list_shared = |model, _context| Ok(Reply.json(model.notes.keep_if(|note| note.shared)))

	list_mine! : AppState, { user : CurrentUser } => Try(Reply, Reply)
	list_mine! = |model, { user: CurrentUser.(user) }|
		Ok(Reply.json(model.notes.keep_if(|note| note.author == user.name)))

	## Answers with the note it would store; this example keeps no state.
	create! : AppState, { user : CurrentUser, body : Extract.JsonBody({ text : Str }) } => Try(Reply, Reply)
	create! = |_model, { user: CurrentUser.(user), body: Extract.JsonBody.({ text }) }|
		Ok(Reply.json({ author: user.name, text }).with_status(201))

	## Only an admin gets here: the route's `AdminOnly` tag is checked before.
	remove! : AppState, { id : Extract.Path(U64) } => Try(Reply, Reply)
	remove! = |model, { id: Extract.Path.(id) }|
		if model.notes.any(|note| note.id == id) {
			Ok(Reply.status(204))
		} else {
			Err(Reply.status(404))
		}
}
