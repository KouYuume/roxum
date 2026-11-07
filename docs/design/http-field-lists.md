# HTTP field list recipient contract

Connection and Expect consume comma-separated lists. Ignore empty elements,
including leading/trailing commas, whitespace-only elements and empty fields,
as required by RFC 9110 section 5.6.1.2. Parsing is linear and bounded by the
existing 32 KiB request-head and 128-header limits; no unbounded list is allocated.
Nonempty Connection elements must be tokens. `close` wins across all fields.
An empty Connection list leaves the HTTP version's default unchanged.

Expect accepts case-insensitive `100-continue` elements; unknown or malformed
nonempty elements produce 417. Empty lists have no expectation. HTTP/1.0 ignores
100-continue (without an interim response); HTTP/1.1 sends 100 only for a framed,
nonempty request body. Unknown expectations remain unsupported in both versions.

Content-Length and Transfer-Encoding have separate framing validation and
ambiguity rejection policies.

Sources: [RFC 9110 section 5.6.1.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.1.2),
[section 10.1.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.1).
