# Responses

A handler returns a `Reply`. `Reply.text`, `Reply.json`, and `Reply.status` cover the plain cases; `Reply.with_status` and
`Reply.with_headers` / `Reply.replace_headers` change any reply. A body written as it goes is
[`Reply.stream`](streaming.md#writing-a-body), and a file is [`Reply.file`](files.md#serving-a-directory).

## JSON

`Reply.json` encodes a value, as axum's `Json` does. A record or a list encodes as it is, and a nominal type opts in with
`encoder_for : _`. The result is always valid JSON, whatever the strings in the value contain.

```roc
Item := { name : Str, count : U64 }.{
	encoder_for : _
}

Reply.json(Item.{ name: "roxum", count: 1 })                  # {"count":1,"name":"roxum"}
Reply.json({ error: "invalid_item" }).with_status(400)
```

A `Str` becomes a JSON string: `Reply.json("ok")` sends `"ok"`. JSON that is already encoded, such as text from a
database, goes through `Reply.bytes(text.to_utf8(), "application/json")`, which sends it as it is.

An `F32` or `F64` does not compile here, because it may be `NaN` or an infinity, which JSON cannot represent. Use `Dec`, or
encode it with `Json.to_str_try` and decide what a failure answers.

## Bytes

`Reply.bytes` takes the media type, so a browser never has to guess one from the content. A string literal is checked at
compile time; a value computed at run time goes through `MediaType.from_str`.

```roc
Reply.bytes(pdf, "application/pdf")
Reply.bytes(data, "application/octet-stream")   # bytes of no known type
```

## HTML

There is no HTML helper yet: roxum's HTML authoring is a later milestone, and its output type decides the shape of one. A
reply can name the type itself. The text is sent as it is, so escape what comes from a request.

```roc
Reply.text(page).replace_headers([ResponseHeader.{ name: HeaderName.("content-type"), value: "text/html; charset=utf-8" }])
```

## Redirects

The name says what the client does next. Each returns `Err(InvalidLocation)` for a value with a control byte. It does not
check where the location goes: a destination that came from a request needs the app's own check, or it is an open redirect.

| Function | Status | The client |
|---|---|---|
| `Redirect.see_other(location)` | 303 | fetches the location with GET, as after a form's POST |
| `Redirect.temporary(location)` | 307 | repeats the same method and body at the location, this time |
| `Redirect.permanent(location)` | 308 | repeats the same method and body there, from now on |

## Downloads

`Reply.attachment(reply, filename)` adds `Content-Disposition` to any reply, plain, streamed, or a file, so a browser saves
it. A name beyond ASCII is sent as RFC 8187 `filename*`, with a plain fallback. It returns `Err(InvalidFilename)` for an
empty name, `.`, `..`, or one with `/`, `\`, or a control byte.

## JSON Lines

`Reply.json_lines` writes one JSON value per line as it goes, for a long export that should not sit in memory. Each value
is encoded as JSON; the helper adds the newline and `Content-Type: application/x-ndjson`.

```roc
Reply.json_lines(|lines| {
	for order in orders {
		JsonLines.write!(lines, order)?
	}
	Ok({})
})
```

## Links to a route

`Path` keeps a route's pattern in one place, for registering it and for building links, so changing the route cannot leave
a link behind. Values are percent-encoded.

```roc
article = Path.new("/articles/{id}")

Router.route(router, Path.pattern(article), MethodRouter.get(show))

Path.url(article, { id: id })   # Ok("/articles/42"), for an id of 42
```

The record's fields hold a `Str`, an integer, a `Dec`, or a `Bool`. Write the name out for a single field: in Roc, `{ id }`
is a block whose value is `id`, not a record, and `Path.url` answers `Err(UnknownParam(""))`. A name is not checked against the pattern at compile
time; `Path.url` returns `Err(MissingParam(name))`, `Err(UnknownParam(name))`, or `Err(InvalidValue(name))` for an empty value,
`.`, or `..`.

## Cookies

The optional [`roxum-cookie`](../../integrations/roxum-cookie/README.md) package sets, removes, and signs cookies.
`Cookie.add` returns `Err` for a cookie a browser would drop, such as `SameSite=None` without `secure`.

```roc
Reply.text("ok") |> Cookie.add(Cookie.{ name: "theme", value: "dark" })
```
