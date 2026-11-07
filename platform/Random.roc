import HostRandom

## Random numbers from the operating system's cryptographically secure source.
## There is no seed and no deterministic generator; to test code that uses
## random values, pass the values in as arguments.
Random := [].{
	## Returns a uniformly random `U64`. The host reads 8 bytes from `getrandom`
	## on Linux and `arc4random_buf` elsewhere. If the source fails, the host
	## stops the process with a fatal error.
	u64! : {} => U64
	u64! = |{}| HostRandom.u64!({})
}
