# roxum-cookie

`roxum-cookie` reads and sets cookies, and signs them. It is optional: the platform does not depend on it.

```roc
import cookie.Cookie

# Set: the attributes default to `Path=/; SameSite=Lax; Secure; HttpOnly`.
Reply.text("ok") |> Cookie.add(Cookie.{ name: "theme", value: "dark" }) ?? Reply.status(500)

# All of them, by type.
Cookie.{
	name: "theme",
	value: "dark",
	path: "/app",
	domain: Cookie.Domain.Of("example.com"),
	max_age: Cookie.MaxAge.Seconds(3600),
	same_site: Cookie.SameSite.Strict,
	secure: Bool.False,
	http_only: Bool.False,
}

# Remove, with the `path` and `domain` it was set with.
reply |> Cookie.remove(Cookie.Removal.{ name: "theme" })

# Read one, or all of them.
Cookie.get(context.request.headers, "theme")
Cookie.all(context.request.headers)

# Read into a record: the field types say what to read.
show! : Model, { cookies : Cookie.Read({ count : U64, theme : Try(Str, [Missing]) }) } => Try(Reply, Reply)
show! = |_model, { cookies: Cookie.Read.(cookies) }| ...
```

`Cookie.add` fails when the name is not an HTTP token, the path or domain could not be sent, the name and value pass
4096 bytes, or browsers would refuse the attributes (`SameSite=None` without `secure`, or a `__Secure-` or `__Host-`
name without what the prefix needs). A browser drops such a cookie without a word, so this is reported here instead.

A value may be any text. It is percent-encoded on the way out and decoded on the way in, as `axum-extra` does; `+` stays
itself. Of a name that repeats, `get` and `Cookie.Read` take the first, and `all` gives every one.

## Signed cookies

```roc
keys = Cookie.Keys.{ current: key, previous: [old_key] }

signed = Cookie.sign!(Cookie.{ name: "user", value: "42" }, keys)?
value = Cookie.verified!(context.request.headers, keys, "user")
```

The value becomes `<HMAC-SHA-256 in hex>.<value>`. The key stays in the host (`Secret.derive!`). The signature covers
the cookie's name, so that it cannot be moved to another cookie, and is compared in time that does not depend on where it
differs. To replace a key, make it `current` and move the old one to `previous`; remove it once the cookies it signed
have ended.

- A signature proves who wrote the value, not that it is secret: the client can read it. Encrypted cookies are not
  provided, because the host has no AEAD yet.
- A signature does not expire. A value that should end holds its own time, and the app checks it.
- `verified!` needs effects, so it is not a `Cookie.Read` field. Call it in the handler, or in a `BeforeBody` stage and
  pass the result through `RequestHead.provided`.
