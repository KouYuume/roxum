import HostFile

## Reading files, such as settings files at startup.
##
## Reads block the request's thread until the file is read, so use them in
## `init!` rather than in handlers that run often.
File := [].{
	## The bytes of the file at `path`, which may be relative to the working
	## directory. A file with more than `maximum_bytes` bytes is not read and
	## gives `FileTooLarge`.
	read_bytes! : Str, U64 => Try(List(U8), [FileNotFound, FilePermissionDenied, FileTooLarge, FileReadFailed])
	read_bytes! = |path, maximum_bytes|
		match HostFile.read!(path, maximum_bytes) {
			Bytes(bytes) => Ok(bytes)
			NotFound => Err(FileNotFound)
			PermissionDenied => Err(FilePermissionDenied)
			TooLarge => Err(FileTooLarge)
			Failed => Err(FileReadFailed)
		}

	## Like `read_bytes!`, for a file that holds UTF-8 text.
	read_utf8! : Str, U64 => Try(Str, [FileNotFound, FilePermissionDenied, FileTooLarge, FileReadFailed, FileNotUtf8])
	read_utf8! = |path, maximum_bytes| {
		bytes = File.read_bytes!(path, maximum_bytes)?
		match Str.from_utf8(bytes) {
			Ok(text) => Ok(text)
			Err(_) => Err(FileNotUtf8)
		}
	}
}
