## Files under a root. Platform code only: apps use `Files` and
## `Reply.file`.
HostFiles := [].{
	## `Opened(handle)`, or why the directory could not be opened as a root.
	RootOpened := [Opened(U64), NotFound, NotDirectory, PermissionDenied, Failed]

	## A file or directory opened under a root, held by the request until
	## `close!` or its end. `modified_seconds` counts from the Unix epoch.
	FileOpened := [
		Opened({ size : U64, modified_seconds : I64, directory : Bool }),
		NotFound,
		Failed,
	]

	open_root! : Str => HostFiles.RootOpened
	## Opens the path under the root, closing any file the request held.
	## A path out of the root is `NotFound`.
	open! : U64, Str => HostFiles.FileOpened
	## Writes `length` bytes of the open file from `offset` to the body
	## started with this stream token; false when the body is over or the
	## file could not be read.
	send! : U64, U64, U64 => Bool
	close! : {} => {}
}
