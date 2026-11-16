import AppState
import Provided
import Tag
import User
import pf.HeaderName
import pf.Middleware
import pf.Reply
import pf.RequestHead
import pf.ResponseHeader
import rate_limit.RateLimit

Layers := [].{

	## BeforeBody: on a route tagged `MembersOnly` or `AdminOnly`, finds the
	## user from `Authorization: Bearer <token>` and leaves it in `provided`, or
	## answers 401 or 403 before the body is received. Other routes pass as
	## they are.
	authenticate : List(Middleware.Stage(AppState, Tag, Provided))
	authenticate = [Middleware.Stage.BeforeBody(|model, head| Layers.admit(model, head))]

	## AfterHandler: replies of routes for signed-in users, refusals included,
	## must not be kept by shared caches.
	no_store : List(Middleware.Stage(AppState, Tag, Provided))
	no_store = [
		Middleware.Stage.AfterHandler(
			|_model, head, reply|
				if Layers.is_private(head) {
					Reply.with_headers(reply, [ResponseHeader.{ name: HeaderName.("cache-control"), value: "private, no-store" }])
				} else {
					reply
				},
		),
	]

	## roxum-rate-limit turns each `Limit(n)` tag into this check, and answers
	## 429 past it. Written after `authenticate`, it sees the user and counts
	## per user.
	post_limit : AppState, RequestHead(Tag, Provided), Tag -> Try(RateLimit.Check, [NoLimit])
	post_limit = |model, head, tag|
		match tag {
			Tag.Limit(limit) => {
				key = match head.provided.user {
					Ok(user) => "posts:${user.name}"
					Err(Unset) => "posts:${
						(
							match head.remote_addr {
								Tcp({ ip, .. }) => RateLimit.client_ip(ip)
								Unix => "unix"
							}
						)
					}"
				}
				Ok(RateLimit.Check.{ counter: model.posts_per_minute, key, limit, on_full: RateLimit.OnFull.Reject })
			}
			Tag.MembersOnly | Tag.AdminOnly => Err(NoLimit)
		}

	## The decision `authenticate` makes, as a pure function.
	admit : AppState, RequestHead(Tag, Provided) -> Try(RequestHead(Tag, Provided), Reply)
	admit = |model, head| {
		if !Layers.is_private(head) {
			return Ok(head)
		}
		user = match Layers.find_user(model, head) {
			Ok(found) => found
			Err(NotSignedIn) =>
				return Err(
					Reply.text("sign in first\n")
						.with_status(401)
						.with_headers([ResponseHeader.{ name: HeaderName.("www-authenticate"), value: "Bearer" }]),
				)
		}
		if head.tags.contains(Tag.AdminOnly) and !User.is_admin(user) {
			return Err(Reply.text("admins only\n").with_status(403))
		}
		Ok({ ..head, provided: Provided.{ user: Ok(user) } })
	}

	is_private : RequestHead(Tag, Provided) -> Bool
	is_private = |head| head.tags.contains(Tag.MembersOnly) or head.tags.contains(Tag.AdminOnly)

	find_user : AppState, RequestHead(Tag, Provided) -> Try(User, [NotSignedIn])
	find_user = |model, head| {
		field = List.find_first(head.headers, |each| each.name == HeaderName.("authorization")).map_err(|_| NotSignedIn)?
		token = match Str.from_utf8(field.value) {
			Ok(text) if text.starts_with("Bearer ") => text.drop_prefix("Bearer ")
			_ => return Err(NotSignedIn)
		}
		match List.find_first(model.users, |each| each.token == token) {
			Ok(found) => Ok(found.user)
			Err(_) => Err(NotSignedIn)
		}
	}
}
