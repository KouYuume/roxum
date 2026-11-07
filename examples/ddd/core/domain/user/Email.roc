import ../../errors/DomainError

Email := Str.{
	is_eq : _
	new : Str -> Try(Email, DomainError)
	new = |value| {
		if value.to_utf8().len() > 254 {
			return Err(DomainError.Validation("email must be at most 254 bytes"))
		}
		match Str.split_on(value, "@") {
			[local, domain] => {
				suffix = List.last(Str.split_on(domain, ".")) ?? ""
				if local == "" or domain == "" or suffix == "" or domain.to_utf8().len() <= suffix.to_utf8().len() + 1 or !(List.contains(domain.to_utf8(), '.')) {
					return Err(DomainError.Validation("invalid email format"))
				}
				for byte in local.to_utf8().concat(domain.to_utf8()) {
					if !(word(byte) or byte == '.' or byte == '-') {
						return Err(DomainError.Validation("invalid email format"))
					}
				}
				for byte in suffix.to_utf8() {
					if !(word(byte)) {
						return Err(DomainError.Validation("invalid email format"))
					}
				}
				Ok(Email.(value))
			}
			_ => Err(DomainError.Validation("invalid email format"))
		}
	}
	as_str = |Email.(value)| value
}

word = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_'

expect Email.new("alice@example.com") == Ok(Email.("alice@example.com"))
expect Email.new("missing-at") == Err(DomainError.Validation("invalid email format"))

## The accepted byte length ends at 254; exercise its immediate neighbors.
email_at_length = |length| Str.from_utf8_lossy(List.repeat('a', length - 4)).concat("@b.c")
expect Email.new(email_at_length(253)) == Ok(Email.(email_at_length(253)))
expect Email.new(email_at_length(254)) == Ok(Email.(email_at_length(254)))
expect Email.new(email_at_length(255)) == Err(DomainError.Validation("email must be at most 254 bytes"))
expect Email.new("@b.c") == Err(DomainError.Validation("invalid email format"))
expect Email.new("a@b") == Err(DomainError.Validation("invalid email format"))
expect Email.new("a@b.") == Err(DomainError.Validation("invalid email format"))
expect Email.new("a@@b.c") == Err(DomainError.Validation("invalid email format"))
expect Email.new("a b@c.d") == Err(DomainError.Validation("invalid email format"))

expect Email.new("a@.b") == Err(DomainError.Validation("invalid email format"))
