import Base64
import pf.Secret

## SCRAM-SHA-256 as PostgreSQL uses it (RFC 5802 / 7677, without channel
## binding). Builds the messages, and the expressions the host evaluates
## with the password (D14); the password never reaches Roc.
PgScram := [].{
	ServerFirst : { nonce : Str, salt : List(U8), iterations : U32 }

	client_first_bare : Str -> Str
	client_first_bare = |client_nonce| "n=,r=${client_nonce}"

	parse_server_first : Str, Str -> Try(PgScram.ServerFirst, [InvalidServerFirst])
	parse_server_first = |client_nonce, server_first| {
		fields = server_first.split_on(",")
		nonce = field(fields, "r")?
		salt = Base64.decode(field(fields, "s")?) ?? []
		iterations = U32.from_str(field(fields, "i")?) ?? 0
		if !nonce.starts_with(client_nonce) or nonce == client_nonce or iterations == 0 or salt.is_empty() {
			Err(InvalidServerFirst)
		} else {
			Ok({ nonce, salt, iterations })
		}
	}

	without_proof : Str -> Str
	without_proof = |nonce| "c=biws,r=${nonce}"

	auth_message : Str, Str, Str -> List(U8)
	auth_message = |first_bare, server_first, final_without_proof| "${first_bare},${server_first},${final_without_proof}".to_utf8()

	## The client proof and the server signature the client expects, as
	## expressions over the password.
	proof_and_signature : PgScram.ServerFirst, List(U8) -> List(Secret.Expr)
	proof_and_signature = |first, auth| {
		salted = Pbkdf2Sha256(SecretValue, Bytes(first.salt), first.iterations)
		client_key = HmacSha256(salted, Bytes("Client Key".to_utf8()))
		proof = Xor(client_key, HmacSha256(Sha256(client_key), Bytes(auth)))
		signature = HmacSha256(HmacSha256(salted, Bytes("Server Key".to_utf8())), Bytes(auth))
		[proof, signature]
	}

	client_final : Str, List(U8) -> Str
	client_final = |final_without_proof, proof| "${final_without_proof},p=${Base64.encode(proof)}"
}

field : List(Str), Str -> Try(Str, [InvalidServerFirst])
field = |fields, name| {
	prefix = "${name}="
	match fields.find_first(|item| item.starts_with(prefix)) {
		Ok(item) => Ok(item.drop_prefix(prefix))
		Err(_) => Err(InvalidServerFirst)
	}
}

expect PgScram.parse_server_first("abc", "r=abcXYZ,s=QUJD,i=4096") == Ok({ nonce: "abcXYZ", salt: "ABC".to_utf8(), iterations: 4096 })
expect PgScram.parse_server_first("abc", "r=xyz,s=QUJD,i=4096") == Err(InvalidServerFirst)
expect PgScram.parse_server_first("abc", "r=abc,s=QUJD,i=4096") == Err(InvalidServerFirst)
expect PgScram.parse_server_first("abc", "r=abcX,s=QUJD,i=0") == Err(InvalidServerFirst)
