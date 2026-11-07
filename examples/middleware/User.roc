User := { name : Str, role : [Member, Admin] }.{
	is_admin : User -> Bool
	is_admin = |user| user.role == Admin
}
