import ../core/errors/ApplicationError
import ../core/errors/DomainError
import pf.Reply

HandlerError := [].{
	from_application : ApplicationError -> Reply
	from_application = |error| match error {
		Domain(DomainError.Validation(message)) => Reply.text(message).with_status(400)
		Infrastructure(_) => Reply.text("database error").with_status(500)
		EntityNotFound(id) => Reply.text("user ${id} not found").with_status(404)
	}
	invalid_request = |{}| Reply.text("invalid request").with_status(400)
}
