import Provided
import User
import pf.Extract
import pf.Reply

## The user `Layers.authenticate` left in `provided`, as a handler's field
## type. On a route without `MembersOnly` or `AdminOnly` nothing sets it, and
## the request is answered with 500: the route is missing its tag.
CurrentUser := User.{
	parser_for = |_encoding|
		Extract.reading(
			|context|
				match context.provided.user {
					Ok(user) => Ok(CurrentUser.(user))
					Err(Unset) => Err(Reply.text("no user for this route\n").with_status(500))
				},
		)
}
