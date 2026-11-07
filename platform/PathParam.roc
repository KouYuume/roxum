## One captured path parameter: the name from the route pattern and the
## percent-decoded value from the request path.
PathParam := {
	name : Str,
	value : Str,
}.{
	is_eq : _
}
