HostSecret := [].{
	## The result of loading a secret into the host.
	##
	## - `Loaded`: the handle of the secret, which the host keeps.
	## - `NotFound`: no file at the path.
	## - `NotSet`: no environment variable with the name.
	## - `PermissionDenied`: the process may not read the file.
	## - `TooLarge`: the secret has more than 4 KiB.
	## - `Failed`: another error, such as a directory at the path.
	## - `TableFull`: the process already holds 64 secrets.
	Load := [
		Loaded(U64),
		NotFound,
		NotSet,
		PermissionDenied,
		TooLarge,
		Failed,
		TableFull,
	]

	from_file! : Str => HostSecret.Load
	from_env! : Str => HostSecret.Load
	derive! : U64, List(U8) => List(U8)
}
