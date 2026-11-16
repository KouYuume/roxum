# Build-time pages

Roc evaluates top-level constants when compiling an application. For content independent of the request, compute a constant and return it with `Handler.static`:

```roc
docs_page : Str
docs_page = Markdown.to_html(docs_source)

routes = Router.new
    .route("/docs", MethodRouter.get(Handler.static(|{}| Reply.text(docs_page))))
```

This example assumes a `Markdown` module and `docs_source` supplied by the application. The entire `Reply` can also be a constant; each request receives its own response ownership.

All three compiler backends support this approach. `zig build test-m9b-2` checks that computed values are embedded and request allocations are released. Expensive constant evaluation adds to build time.

Content that depends on path parameters, query values, or headers must be computed from the request. When the input set is bounded, initialization can precompute values into the model. For files on disk, use [file serving](files.md).

HTML templates can also be compiled ahead of time into rendering functions that accept dynamic data. This does not make the rendered HTML a build-time constant. Such generators belong in independent tools and libraries; roxum does not bundle one. See [HTML templates and AOT generation](../design/non-goals.md#html-templates-and-aot-generation) for the intended boundary, including HTML fragments sent over SSE.
