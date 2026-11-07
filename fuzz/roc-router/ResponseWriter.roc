# Fuzz-only stand-in for platform/ResponseWriter.roc, whose write calls the
# host, which the roc-fuzz platform cannot bind. Reply only names the types.
ResponseWriter :: U64.{
	Options := {
		keep_alive : ResponseWriter.KeepAlive ?? ResponseWriter.KeepAlive.None,
		ends_on_drain : Bool ?? Bool.False,
	}

	KeepAlive := [None, Every({ milliseconds : U64, bytes : List(U8) })]

	write! : ResponseWriter, List(U8) => Try({}, [StreamClosed])
	write! = |_writer, _bytes| Err(StreamClosed)
}
