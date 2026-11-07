import User
import pf.RateCounter

## The people who can sign in and the notes. A real app would keep both in a
## database and check sessions; here they are fixed at startup.
AppState := {
	users : List({ token : Str, user : User }),
	notes : List(AppState.Note),
	posts_per_minute : RateCounter,
}.{
	Note : { id : U64, author : Str, text : Str, shared : Bool }

	new! : {} => Try(AppState, [StartupErr(Str)])
	new! = |{}| {
		posts_per_minute = match RateCounter.new!({ window_seconds: 60, max_keys: 10000 }) {
			Ok(counter) => counter
			Err(_) => return Err(StartupErr("could not make the rate counter"))
		}
		Ok(AppState.{
			users: [
				{ token: "alice-token", user: User.{ name: "alice", role: Member } },
				{ token: "admin-token", user: User.{ name: "admin", role: Admin } },
			],
			notes: [
				{ id: 1, author: "alice", text: "Shared with everyone", shared: Bool.True },
				{ id: 2, author: "alice", text: "Only for alice", shared: Bool.False },
			],
			posts_per_minute,
		})
	}
}
