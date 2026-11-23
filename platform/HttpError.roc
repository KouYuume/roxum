import Status

## An HTTP error response: a status and a message, such as
## `HttpError.{ status: 409, message: "the name is taken" }`. `Reply.error`
## turns it into a response whose body is the message as plain text
## (`content-type: text/plain; charset=utf-8`). The message is sent to the
## client, so do not put internal details in it.
HttpError := { status : Status, message : Str }.{
	## A 400 Bad Request error.
	bad_request : Str -> HttpError
	bad_request = |message| HttpError.{ status: 400, message }
	## A 401 Unauthorized error. No `WWW-Authenticate` header is added.
	unauthorized : Str -> HttpError
	unauthorized = |message| HttpError.{ status: 401, message }
	## A 403 Forbidden error.
	forbidden : Str -> HttpError
	forbidden = |message| HttpError.{ status: 403, message }
	## A 404 Not Found error.
	not_found : Str -> HttpError
	not_found = |message| HttpError.{ status: 404, message }
	## A 500 Internal Server Error.
	internal : Str -> HttpError
	internal = |message| HttpError.{ status: 500, message }
}
