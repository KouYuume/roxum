Abi :: [].{
	Choice := [
		Empty,
		Byte(U8),
		Pair({ left : U16, right : U64 }),
		Text(Str),
	]

	Probe := {
		code : U64,
		empty : Str,
		short : Str,
		long : Str,
		list_empty : List(U8),
		list_one : List(U8),
		list_many : List(U8),
		choice : Abi.Choice,
	}
}
