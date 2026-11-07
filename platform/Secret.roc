import HostSecret

## A password, token, or key that the host keeps and Roc never sees.
##
## The runtime injects secrets, as a file (Kubernetes secrets, Docker
## secrets, systemd credentials) or an environment variable (ECS, `op run`).
## Load each one in `init!` and keep the handle in the model. Clients such as
## a PostgreSQL or HTTP client use it through `derive!`, which computes with
## the secret in the host and returns only results that cannot give the
## secret back.
##
## The point is to keep secrets out of logs, crash messages, and debug
## output by mistake. It does not contain code written to steal them; app
## code is trusted.
Secret :: U64.{
	## A computation the host performs with the secret. `SecretValue` stands
	## for the secret's bytes.
	Expr := [
		SecretValue,
		Bytes(List(U8)),
		Sha256(Secret.Expr),
		Sha1(Secret.Expr),
		Md5(Secret.Expr),
		## The key, then the message.
		HmacSha256(Secret.Expr, Secret.Expr),
		## The password, the salt, then the iteration count. Gives 32 bytes.
		Pbkdf2Sha256(Secret.Expr, Secret.Expr, U32),
		## Both sides must have the same length.
		Xor(Secret.Expr, Secret.Expr),
		Concat(Secret.Expr, Secret.Expr),
		## 4 big-endian bytes: the length of the expression's result plus the
		## number, as some protocols prefix a message with its length.
		Be32LengthPlus(Secret.Expr, U32),
	]

	## Reads a secret from the file at `path`. One trailing newline is
	## dropped, since `echo secret > file` adds one.
	from_file! : Str => Try(Secret, [SecretNotFound, SecretPermissionDenied, SecretTooLarge, SecretReadFailed, SecretTableFull])
	from_file! = |path|
		match HostSecret.from_file!(path) {
			Loaded(handle) => Ok(Secret.(handle))
			NotFound => Err(SecretNotFound)
			PermissionDenied => Err(SecretPermissionDenied)
			TooLarge => Err(SecretTooLarge)
			TableFull => Err(SecretTableFull)
			_ => Err(SecretReadFailed)
		}

	## Reads a secret from the environment variable `name`. Environment
	## variables are read only here, for secrets a runtime injects; settings
	## come from files.
	from_env! : Str => Try(Secret, [SecretNotSet, SecretTooLarge, SecretTableFull])
	from_env! = |name|
		match HostSecret.from_env!(name) {
			Loaded(handle) => Ok(Secret.(handle))
			TooLarge => Err(SecretTooLarge)
			TableFull => Err(SecretTableFull)
			_ => Err(SecretNotSet)
		}

	## The results of `exprs`, in order. Refused when a result contains the
	## secret without a hash, HMAC, or PBKDF2 in between.
	derive! : Secret, List(Secret.Expr) => Try(List(List(U8)), [SecretExposed, SecretInvalidExpr, SecretUnknown])
	derive! = |secret, exprs| {
		reply = HostSecret.derive!(Secret.handle(secret), Secret.encode(exprs))
		match reply.first() {
			Ok(0) => Ok(split_outputs(reply.drop_first(1)))
			Ok(1) => Err(SecretExposed)
			Ok(3) => Err(SecretUnknown)
			_ => Err(SecretInvalidExpr)
		}
	}

	## The postfix encoding the host evaluates: each expression ends in an
	## output instruction. Used by host functions that take expressions,
	## such as `Tcp.write_derived!`.
	encode : List(Secret.Expr) -> List(U8)
	encode = |exprs| exprs.join_map(|expr| encode_one(expr).append(0xF0))

	## The host's handle, for host functions that take a secret.
	handle : Secret -> U64
	handle = |Secret.(value)| value
}

encode_one : Secret.Expr -> List(U8)
encode_one = |expr|
	match expr {
		SecretValue => [0x01]
		Bytes(bytes) => [0x02].concat(be32(bytes.len().to_u32_wrap())).concat(bytes)
		Sha256(inner) => encode_one(inner).append(0x10)
		Sha1(inner) => encode_one(inner).append(0x11)
		Md5(inner) => encode_one(inner).append(0x12)
		HmacSha256(key, message) => encode_one(key).concat(encode_one(message)).append(0x20)
		Pbkdf2Sha256(password, salt, iterations) => encode_one(password).concat(encode_one(salt)).append(0x21).concat(be32(iterations))
		Xor(left, right) => encode_one(left).concat(encode_one(right)).append(0x30)
		Concat(left, right) => encode_one(left).concat(encode_one(right)).append(0x31)
		Be32LengthPlus(inner, extra) => encode_one(inner).append(0x32).concat(be32(extra))
	}

be32 : U32 -> List(U8)
be32 = |value| [value.shr_zf_wrap(24).to_u8_wrap(), value.shr_zf_wrap(16).to_u8_wrap(), value.shr_zf_wrap(8).to_u8_wrap(), value.to_u8_wrap()]

split_outputs : List(U8) -> List(List(U8))
split_outputs = |bytes| {
	var $rest = bytes
	var $outputs = []
	while $rest.len() >= 4 {
		var $length = 0
		for byte in $rest.take_first(4) {
			$length = $length * 256 + byte.to_u64()
		}
		length = $length
		$outputs = $outputs.append($rest.sublist({ start: 4, len: length }))
		$rest = $rest.drop_first(4 + length)
	}
	$outputs
}

expect Secret.encode([SecretValue]) == [0x01, 0xF0]
expect Secret.encode([Sha256(Bytes([7]))]) == [0x02, 0, 0, 0, 1, 7, 0x10, 0xF0]
expect Secret.encode([Pbkdf2Sha256(SecretValue, Bytes([]), 4096)]) == [0x01, 0x02, 0, 0, 0, 0, 0x21, 0, 0, 0x10, 0, 0xF0]
expect split_outputs([0, 0, 0, 2, 9, 8, 0, 0, 0, 0]) == [[9, 8], []]
