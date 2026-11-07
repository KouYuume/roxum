HostFile := [].{
	## The result of `File.read_bytes!`.
	##
	## - `Bytes`: the whole file, at most the requested number of bytes.
	## - `NotFound`: no file at the path.
	## - `PermissionDenied`: the process may not read it.
	## - `TooLarge`: the file has more bytes than requested.
	## - `Failed`: another error, such as a directory at the path.
	Read := [
		Bytes(List(U8)),
		NotFound,
		PermissionDenied,
		TooLarge,
		Failed,
	]

	read! : Str, U64 => HostFile.Read
}
