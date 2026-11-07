# Fuzz-only stand-in for platform/HostInstant.roc, whose clock is a hosted
# call the roc-fuzz platform cannot bind. The fuzz target never reads it.
HostInstant := [].{
	now_nanoseconds! : {} => U64
	now_nanoseconds! = |{}| 0
}
