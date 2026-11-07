# Files and compression

roxum serves files from a directory you open at startup, and compresses responses with gzip on the routes you ask
for. `zig build test-files` and `zig build test-compression` check both in every backend.

A reverse proxy can do either in front of roxum (nginx's `location` with `root`, and `gzip`); see
[Deployment](deployment.md#what-the-proxy-and-roxum-each-do) for which to leave to it.

## Serving a directory

Open the directory as a root in `init!` and keep it in the model. A root that cannot be opened stops startup.

```roc
Model := { public : FileRoot }

init! = |{}| {
	public = match Files.open_root!("public") {
		Ok(root) => root
		Err(_) => return Err(StartupErr("public cannot be opened"))
	}
	Ok({ model: { public }, listen: Server.ListenOptions.{ ... } })
}
```

Serve all of it with `Files.serve`, at the route's last path parameter. The root is opened after the routes are
built, so `Files.serve` takes the function that finds it in the model:

```roc
routes = Router.new.route("/static/{*path}", MethodRouter.get(Files.serve(|model| model.public)))
```

Or reply with one file from a handler, after checking what it needs to, with `Reply.file`:

```roc
invoice = |model, context| {
	user = authorize(context)?
	Ok(Reply.file(model.invoices, "${user.id}.pdf"))
}
```

Either way:

- The `content-type` comes from the file's extension; one the reply sets with `Reply.with_headers` wins
- Nothing leads out of the root: not `..`, not an absolute path, and not a symbolic link that points outside (a
  link that stays inside works, as with Go's `os.Root`). What does is 404, as is a file that does not exist
- A directory answers with its `index.html` when the URL path ends in `/`, and otherwise redirects (301) to the URL
  with the `/`. There are no directory listings
- **Everything under the root is public, dotfiles included.** A file whose name starts with `.`, such as `.env` or
  `.git/config`, is served like any other. Keeping such files out of the root is your responsibility
- The response has `ETag` and `Last-Modified`, and `If-None-Match` or `If-Modified-Since` that match get 304
- A single byte range (`Range: bytes=...`) gets 206, and one past the end 416. Several ranges, or another unit, get
  the whole file with 200
- The host reads the file in 64 KiB parts on threads of its own, so a slow disk does not hold other requests, and
  sends it with `Content-Length`. A file being sent counts as a stream in `Server.Limits.maximum_streams`

### Precompressed files

Compress the files when the app is built (`app.js.br`, `app.js.gz` beside `app.js`), and open the root with them:

```roc
Files.open_root_with!("public", Files.RootOptions.{ precompressed: [Files.Precompressed.Brotli, Files.Precompressed.Gzip] })
```

A client that accepts Brotli then gets `app.js.br` with `content-encoding: br`, in the order you list them. Every
response from such a root has `vary: accept-encoding`. Brotli is only served this way: roxum does not compress with
it at run time.

## Compressing responses

Add `Compression.layer` to the routes whose responses should be compressed:

```roc
routes =
	Router.new
		.route("/api/items", MethodRouter.get(Handler.effectful(list_items!)))
		.layer(Compression.layer(Compression.Options.{}))
```

A response is compressed with gzip when the client accepts gzip, its body is over `above_bytes` (32 by default), it
has no `content-encoding` yet, and it is not an image (but SVG), gRPC, or server-sent events, as tower-http's
`CompressionLayer` does. Each such response gets `vary: accept-encoding`, whether or not this client accepts gzip; a
body at or under `above_bytes` is sent as it is, without `vary`. The host compresses off the request threads.

- A body written as it goes (`Reply.stream`) is compressed part by part: each write reaches the client at once. The
  keep-alive bytes are compressed with it, and a body that ends on a drain still ends its gzip stream
- A file is compressed whole, sent chunked as its length is not known then. A request for a range is not
  compressed, and neither is a precompressed file again
- Do not compress responses that hold a secret and text from the request in one body on TLS: their compressed length
  can tell the secret (BREACH)

The HTTP client decompresses gzip and Zstandard responses by itself; see
[Calling HTTP APIs](http-client.md#compressed-responses). `Compression.decompress_requests` is a layer for request
bodies ([Extractors](extractors.md#compressed-request-bodies)), and `Compression.decompress!` is there for other bodies.
