app [program] {
	pf: platform "../../platform/main.roc",
	hc: "../../integrations/roxum-http-client/package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import "config/base.toml" as base_text : Str
import hc.HttpClient
import http.Method
import http.Request
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.RouteContext
import pf.Router
import pf.Secret
import pf.Server

## Calls the upstream servers the test runs and replies with the status and
## body it got, or with the error's name. `/{call}/{target}/{path}` picks
## how to call and which server; `path` is one segment the upstream reads
## as an instruction (see verify.py).
Settings : {
	plain_port : U16,
	ec_port : U16,
	rsa_port : U16,
	closed_port : U16,
	ca_file : Str,
}

Model := {
	settings : Settings,
	client : HttpClient.Client,
	small : HttpClient.Client,
	system : HttpClient.Client,
	no_retry : HttpClient.Client,
	raw : HttpClient.Client,
	secret : Secret,
}

program = { init!, routes: Router.build(routes, {}) }

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	client! = |config| HttpClient.client!(config).map_err(|_| StartupErr("client"))
	HttpClient.configure!(HttpClient.Limits.{ maximum_requests_per_host: Server.Count.Fixed(64) }).map_err(|_| StartupErr("limits"))?
	model = {
		settings,
		client: client!(HttpClient.Config.{ ca: HttpClient.Ca.File(settings.ca_file) })?,
		small: client!(HttpClient.Config.{ ca: HttpClient.Ca.File(settings.ca_file), maximum_body_bytes: 1_000, maximum_redirects: 2 })?,
		system: client!(HttpClient.Config.{})?,
		no_retry: client!(HttpClient.Config.{ ca: HttpClient.Ca.File(settings.ca_file), retry_on_stale_connection: Bool.False })?,
		raw: client!(HttpClient.Config.{ ca: HttpClient.Ca.File(settings.ca_file), decompress: Bool.False })?,
		secret: Secret.from_env!("ROXUM_TEST_SECRET").map_err(|_| StartupErr("secret"))?,
	}
	Ok({
		model,
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/{call}/{target}/{path}", MethodRouter.get(Handler.effectful(call!)))

call! : Model, RouteContext({}) => Try(Reply, Reply)
call! = |model, context| {
	settings = model.settings
	path = param(context, "path")
	uri = match param(context, "target") {
		"plain" => "http://127.0.0.1:${settings.plain_port.to_str()}/${path}"
		"other" => "http://localhost:${settings.plain_port.to_str()}/${path}"
		"ec" => "https://localhost:${settings.ec_port.to_str()}/${path}"
		"rsa" => "https://localhost:${settings.rsa_port.to_str()}/${path}"
		"wrong-name" => "https://127.0.0.1:${settings.ec_port.to_str()}/${path}"
		"refused" => "http://127.0.0.1:${settings.closed_port.to_str()}/${path}"
		"unresolvable" => "http://name-that-does-not-exist.invalid/${path}"
		_ => "ftp://example.com/"
	}
	get = Request.from_method(Method.GET).with_uri(uri)
	answer = match param(context, "call") {
		"get" => HttpClient.send!(model.client, get)
		"head" => HttpClient.send!(model.client, get.with_method(Method.HEAD))
		"post" => HttpClient.send!(model.client, get.with_method(Method.POST).with_body("payload".to_utf8()).add_header("Content-Type", "text/plain"))
		"post-no-retry" => HttpClient.send!(model.no_retry, get.with_method(Method.POST))
		"get-no-retry" => HttpClient.send!(model.no_retry, get)
		"small" => HttpClient.send!(model.small, get)
		"system" => HttpClient.send!(model.system, get)
		"timeout" => HttpClient.send!(model.client, get.with_timeout(TimeoutMilliseconds(300)))
		"auth" => HttpClient.send!(model.client, get.add_header("Authorization", "Basic dXNlcjpwYXNz").add_header("X-Kept", "kept"))
		"secret" => HttpClient.send_with!(model.client, get, HttpClient.SendOptions.{ secret_headers: [{ name: "Authorization", prefix: "Bearer ", secret: model.secret }] })
		"bad-header" => HttpClient.send!(model.client, get.add_header("X-Bad", "a\r\nInjected: 1"))
		"raw" => HttpClient.send!(model.raw, get)
		"own-accept" => HttpClient.send!(model.client, get.add_header("Accept-Encoding", "gzip"))
		"configure-late" =>
			match HttpClient.configure!(HttpClient.Limits.{}) {
				Ok({}) => HttpClient.send!(model.client, get)
				Err(HttpClientInvalidConfig) => return Ok(Reply.text("HttpClientInvalidConfig\n"))
			}
		_ => HttpClient.send!(model.client, get.with_method(Method.Unknown("BAD METHOD")))
	}
	text = match answer {
		Ok(response) => {
			encoding = match List.find_first(response.headers(), |header| header.name.caseless_ascii_equals("content-encoding")) {
				Ok(header) => " (${header.value})"
				Err(_) => ""
			}
			"${response.status().to_str()} ${Str.from_utf8_lossy(response.body())}${encoding}"
		}
		Err(HttpClientInvalidUrl(_)) => "HttpClientInvalidUrl"
		Err(HttpClientInvalidMethod) => "HttpClientInvalidMethod"
		Err(HttpClientInvalidHeader(name)) => "HttpClientInvalidHeader ${name}"
		Err(TcpResolveFailed) => "TcpResolveFailed"
		Err(TcpResolveTimedOut) => "TcpResolveTimedOut"
		Err(TcpConnectFailed) => "TcpConnectFailed"
		Err(TcpConnectTimedOut) => "TcpConnectTimedOut"
		Err(TcpTlsFailed) => "TcpTlsFailed"
		Err(HttpClientBusy) => "HttpClientBusy"
		Err(HttpClientTimedOut) => "HttpClientTimedOut"
		Err(HttpClientClosed) => "HttpClientClosed"
		Err(HttpClientInvalidResponse(_)) => "HttpClientInvalidResponse"
		Err(HttpClientBodyTooLarge) => "HttpClientBodyTooLarge"
		Err(HttpClientTooManyRedirects) => "HttpClientTooManyRedirects"
		Err(HttpClientInsecureRedirect) => "HttpClientInsecureRedirect"
		Err(HttpClientOverloaded) => "HttpClientOverloaded"
	}
	Ok(Reply.text("${text}\n"))
}

param : RouteContext({}), Str -> Str
param = |context, name|
	match List.first(List.keep_if(context.path_params, |item| item.name == name)) {
		Ok(found) => found.value
		Err(_) => ""
	}
