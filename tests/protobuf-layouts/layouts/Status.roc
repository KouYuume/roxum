## Candidate open enum: aliases share a value and unknown numbers remain intact.
Status := I32.{
	is_eq : _
	unspecified : Status
	unspecified = Status.(0)
	ready : Status
	ready = Status.(1)
	available : Status
	available = Status.(1)
	from_number : I32 -> Status
	from_number = |number| Status.(number)
	to_number : Status -> I32
	to_number = |Status.(number)| number
}
