import pf.Log

PurityViolation := [].{
	write : Str -> {}
	write = |message| Log.info!(message)
}
