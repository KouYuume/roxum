import Email
import ../../errors/DomainError

User := { id : Str, name : Str, email : Email }.{
	is_eq : _
	Data : { id : Str, name : Str, email : Str }
	to_data : User -> User.Data
	to_data = |user| { id: user.id, name: user.name, email: Email.as_str(user.email) }
	new : User.Data -> Try(User, DomainError)
	new = |data| Ok({ id: data.id, name: data.name, email: Email.new(data.email)? })
	id = |user| user.id
	name = |user| user.name
	email = |user| Email.as_str(user.email)
}

expect match User.new({ id: "id", name: "Alice", email: "alice@example.com" }) {
	Ok(user) => User.id(user) == "id" and User.name(user) == "Alice" and User.email(user) == "alice@example.com"
	Err(_) => Bool.False
}
expect User.new({ id: "id", name: "Alice", email: "invalid" }) == Err(DomainError.Validation("invalid email format"))
