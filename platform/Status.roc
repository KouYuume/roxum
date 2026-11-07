## A final HTTP status code, in the range 200..599. A number literal typed as
## `Status` is checked at compile time. Informational (1xx) statuses are not
## final responses, and the host does not send them for a handler, so they
## are rejected here rather than turned into a 500 at run time:
##
## ```roc
## not_found : Status
## not_found = 404
## ```
##
## Use `from_u16` for values known only at run time.
Status :: U16.{
	is_eq : _

	## Converts a number literal typed as `Status`. A value outside 200..599 is a
	## compile-time error.
	from_numeral : Numeral -> Try(Status, [InvalidNumeral(Str)])
	from_numeral = |numeral|
		match U16.from_numeral(numeral) {
			Ok(value) =>
				match Status.from_u16(value) {
					Ok(status) => Ok(status)
					Err(InvalidStatus) => Err(InvalidNumeral("HTTP status must be in 200..599"))
				}
			Err(error) => Err(error)
		}

	## Returns `Err(InvalidStatus)` unless `value` is in 200..599.
	from_u16 : U16 -> Try(Status, [InvalidStatus])
	from_u16 = |value|
		if value >= 200 and value <= 599 {
			Ok(Status.(value))
		} else {
			Err(InvalidStatus)
		}

	## The numeric status code.
	code : Status -> U16
	code = |Status.(value)| value
}

expect Status.from_u16(100) == Err(InvalidStatus)
expect Status.from_u16(199) == Err(InvalidStatus)
expect Status.from_u16(200) == Ok(Status.(200))
expect Status.from_u16(201) == Ok(Status.(201))
expect Status.from_u16(599) == Ok(Status.(599))
expect Status.from_u16(600) == Err(InvalidStatus)

expect {
	status : Status
	status = 418
	Status.code(status) == 418
}
