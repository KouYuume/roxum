app [program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Secret
import pf.IpAddr
import pf.Server

## The secrets come from the environment and a file the test prepares; the
## working directory holds `data/`.
Model := { from_env : Secret, from_file : Secret }

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	from_env = match Secret.from_env!("ROXUM_TEST_SECRET") {
		Ok(secret) => secret
		Err(_) => return Err(StartupErr("ROXUM_TEST_SECRET is not set"))
	}
	from_file = match Secret.from_file!("data/secret.txt") {
		Ok(secret) => secret
		Err(_) => return Err(StartupErr("data/secret.txt cannot be read"))
	}
	Ok({
		model: { from_env, from_file },
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/file/{name}", MethodRouter.get(Handler.effectful(read_file!)))
		.route("/sha256/{source}", MethodRouter.get(Handler.effectful(sha256!)))
		.route("/exposed", MethodRouter.get(Handler.effectful(exposed!)))

## Reads `data/<name>` with a limit of 8 bytes.
read_file! : Model, RouteContext({}) => Try(Reply, Reply)
read_file! = |_model, context| {
	text = match File.read_utf8!("data/${path_param(context, "name")}", 8) {
		Ok(content) => "ok ${content}"
		Err(FileNotFound) => "FileNotFound"
		Err(FilePermissionDenied) => "FilePermissionDenied"
		Err(FileTooLarge) => "FileTooLarge"
		Err(FileReadFailed) => "FileReadFailed"
		Err(FileNotUtf8) => "FileNotUtf8"
	}
	Ok(Reply.text("${text}\n"))
}

sha256! : Model, RouteContext({}) => Try(Reply, Reply)
sha256! = |model, context| {
	secret = if path_param(context, "source") == "env" { model.from_env } else { model.from_file }
	match Secret.derive!(secret, [Sha256(SecretValue)]) {
		Ok([digest]) => Ok(Reply.text("${hex(digest)}\n"))
		_ => Err(Reply.text("derive failed\n").with_status(500))
	}
}

## Asks for the secret itself; the host refuses.
exposed! : Model, RouteContext({}) => Try(Reply, Reply)
exposed! = |model, _context|
	match Secret.derive!(model.from_env, [Concat(Bytes("x".to_utf8()), SecretValue)]) {
		Ok(_) => Ok(Reply.text("not refused\n"))
		Err(SecretExposed) => Ok(Reply.text("SecretExposed\n"))
		Err(_) => Ok(Reply.text("other error\n"))
	}

hex : List(U8) -> Str
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	for byte in bytes {
		$out = $out.append(digits.get(byte.shr_zf_wrap(4).to_u64()) ?? '0')
		$out = $out.append(digits.get(byte.bitwise_and(0x0f).to_u64()) ?? '0')
	}
	Str.from_utf8($out) ?? ""
}

path_param : RouteContext({}), Str -> Str
path_param = |context, name|
	match List.first(List.keep_if(context.path_params, |param| param.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
