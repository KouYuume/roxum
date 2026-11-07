import HeaderValue
import Http
import Reply
import Status

## Location-based redirects with an empty body. These helpers check header
## safety, not URI syntax or an allowed-origin/scheme policy. Supply a URI
## reference built by the application; untrusted destinations need its policy.
Redirect :: [].{

	## 303 See Other: the client fetches the destination with GET, as after a
	## form's POST.
	see_other : Str -> Try(Reply, [InvalidLocation])
	see_other = |location| make(303, location)

	## 307 Temporary Redirect: preserve the original method and body.
	temporary : Str -> Try(Reply, [InvalidLocation])
	temporary = |location| make(307, location)

	## 308 Permanent Redirect: preserve the original method and body.
	permanent : Str -> Try(Reply, [InvalidLocation])
	permanent = |location| make(308, location)
}

make : Status, Str -> Try(Reply, [InvalidLocation])
make = |status, location| {
	# HeaderValue rejects CR/LF only. Reject all C0 controls and DEL here,
	# so malformed values fail before the host attempts to write a reply.
	if location.to_utf8().any(|b| b < 32 or b == 127) {
		return Err(InvalidLocation)
	}
	value = match HeaderValue.from_str(location) {
		Ok(header) => header
		Err(_) => return Err(InvalidLocation)
	}
	Ok(Reply.status(status).replace_headers([Http.ResponseHeader.{ name: Http.HeaderName.("location"), value }]))
}

# Header safety boundaries; URI validity is a separate application concern.
expect match Redirect.see_other("/\u(1F)") {
	Err(InvalidLocation) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/ ") {
	Ok(_) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/!") {
	Ok(_) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/~") {
	Ok(_) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/\u(7F)") {
	Err(InvalidLocation) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/\u(80)") {
	Ok(_) => Bool.True
	_ => Bool.False
}
expect match Redirect.see_other("/\r\nx: injected") {
	Err(InvalidLocation) => Bool.True
	_ => Bool.False
}
