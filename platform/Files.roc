import FileRoot
import Handler
import HostFiles
import Reply

## Serving files from a directory. Open the directory as a root in
## `init!` and keep it in the model; serve all of it with `serve`, or reply
## with one file with `Reply.file(root, path)` after checking what the
## handler needs to:
##
## ```roc
## init! = |{}| {
##     public = Files.open_root!("public").map_err(|_| StartupErr("no public directory"))?
##     Ok({ model: { public }, listen: ... })
## }
##
## routes =
##     Router.new
##         .route("/static/{*path}", MethodRouter.get(Files.serve(|model| model.public)))
## ```
##
## Either way the response has a `content-type` from the file's extension,
## `ETag` and `Last-Modified`, and answers conditional requests (304) and a
## single byte range (206). A directory answers with its `index.html` when
## the URL path ends in `/`, and redirects to that URL otherwise. The host
## reads files off the request threads, so a slow disk does not hold other
## requests.
Files := [].{
	## Opens the directory at `path`, which may be relative to the working
	## directory, as a root.
	open_root! : Str => Try(FileRoot, [RootNotFound, RootNotDirectory, RootPermissionDenied, RootOpenFailed])
	open_root! = |path| Files.open_root_with!(path, Files.RootOptions.{})

	## Like `open_root!`, with `options`.
	open_root_with! : Str, Files.RootOptions => Try(FileRoot, [RootNotFound, RootNotDirectory, RootPermissionDenied, RootOpenFailed])
	open_root_with! = |path, options|
		match HostFiles.open_root!(path) {
			HostFiles.RootOpened.Opened(handle) => Ok(FileRoot.from_handle(handle, List.map(options.precompressed, coding_of)))
			HostFiles.RootOpened.NotFound => Err(RootNotFound)
			HostFiles.RootOpened.NotDirectory => Err(RootNotDirectory)
			HostFiles.RootOpened.PermissionDenied => Err(RootPermissionDenied)
			HostFiles.RootOpened.Failed => Err(RootOpenFailed)
		}

	## How a root serves its files.
	##
	## `precompressed` lists the precompressed files to look for, in the order
	## the server prefers them: with `[Files.Precompressed.Brotli,
	## Files.Precompressed.Gzip]`, a request for `app.js` from a client that
	## accepts Brotli gets `app.js.br` when it exists, with
	## `content-encoding: br`. Compress them when the app is built.
	RootOptions := {
		precompressed : List(Files.Precompressed) ?? [],
	}

	## A precompressed file beside the original: `.br` or `.gz`.
	Precompressed := [Brotli, Gzip]

	## A handler that serves the file at the route's last path parameter,
	## such as `{*path}`, under the root `root_of` takes from the model: the
	## root is opened in `init!`, after the routes are built.
	serve : (model -> FileRoot) -> Handler(model, tag, provided)
	serve = |root_of|
		Handler.stateful(
			|model, context| {
				path = match List.last(context.path_params) {
					Ok(param) => param.value
					Err(_) => ""
				}
				Ok(Reply.file(root_of(model), path))
			},
		)
}

coding_of : Files.Precompressed -> { suffix : Str, coding : Str }
coding_of = |precompressed|
	match precompressed {
		Files.Precompressed.Brotli => { suffix: ".br", coding: "br" }
		Files.Precompressed.Gzip => { suffix: ".gz", coding: "gzip" }
	}
