import Status

## An HTTP error response: a status and a message. `Reply.error` turns it into
## a response whose body is the message as plain text
## (`content-type: text/plain; charset=utf-8`). The message is sent to the
## client, so do not put internal details in it.
HttpError :: { status : Status, message : Str }.{
	## An error with any status.
	make = |status, message| HttpError.({ status, message })
	## A 400 Bad Request error.
	bad_request = |message| HttpError.({ status: 400, message })
	## A 401 Unauthorized error. No `WWW-Authenticate` header is added.
	unauthorized = |message| HttpError.({ status: 401, message })
	## A 403 Forbidden error.
	forbidden = |message| HttpError.({ status: 403, message })
	## A 404 Not Found error.
	not_found = |message| HttpError.({ status: 404, message })
	## A 500 Internal Server Error.
	internal = |message| HttpError.({ status: 500, message })
	## The error's status.
	status = |HttpError.(error)| error.status
	## The error's message.
	message = |HttpError.(error)| error.message
}
