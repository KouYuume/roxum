## A directory opened with `Files.open_root!`: files are served from
## under it, and no path or symbolic link leads out of it. Keep it in the
## model.
FileRoot :: {
	handle : U64,
	## Precompressed files to look for beside each file, in the order the
	## server prefers them: the file name's suffix and its content coding.
	precompressed : List({ suffix : Str, coding : Str }),
}.{
	## The host's handle. Platform code only.
	handle : FileRoot -> U64
	handle = |FileRoot.(root)| root.handle

	## The precompressed files to look for. Platform code only.
	precompressed : FileRoot -> List({ suffix : Str, coding : Str })
	precompressed = |FileRoot.(root)| root.precompressed

	## A root from the host's handle. Platform code only.
	from_handle : U64, List({ suffix : Str, coding : Str }) -> FileRoot
	from_handle = |value, variants| FileRoot.({ handle: value, precompressed: variants })
}
