platform "roxum"
	requires {
		[Model : model] for program : {
			init! : {} => Try({ model : model, listen : Server.ListenOptions }, [StartupErr(Str)]),
			routes : Routes(model),
		}
	}
	exposes [
		BodyLimit,
		Compression,
		Concurrency,
		Config,
		Extract,
		Extractor,
		File,
		FileRoot,
		Files,
		Handler,
		HeaderValue,
		Http.HeaderName,
		Http.IpAddr,
		Http.Method,
		Http.RemoteAddr,
		Http.Request,
		Http.RequestBody,
		Http.RequestHeader,
		Http.Response,
		Http.ResponseBody,
		Http.ResponseHeader,
		Http.Version,
		HttpError,
		Instant,
		JsonLines,
		Log,
		MediaType,
		MethodRouter,
		Middleware,
		Multipart,
		MultipartBody,
		Path,
		PathParam,
		PathSegment,
		QueryValue,
		Random,
		RateCounter,
		Redirect,
		Reply,
		RequestHead,
		Respond,
		ResponseWriter,
		RouteContext,
		RouteError,
		RouteProbe,
		Router,
		Routes,
		Secret,
		Server,
		Sleep,
		Status,
		Tcp,
		Time,
		UrlEncoded,
	]
	packages { toml: "../libraries/roc-toml/package/main.roc" }
	provides {
		"roc_handle": handle_for_host!,
		"roc_init": init_for_host!,
	}
	hosted {
		"roxum_body_limit_streamed": HostBody.limit_streamed!,
		"roxum_body_limit_whole": HostBody.limit_whole!,
		"roxum_body_read": HostBody.read!,
		"roxum_compress_decompress": HostCompress.decompress!,
		"roxum_compress_gzip": HostCompress.gzip!,
		"roxum_concurrency_acquire": HostConcurrency.acquire!,
		"roxum_concurrency_new": HostConcurrency.new!,
		"roxum_file_read": HostFile.read!,
		"roxum_files_close": HostFiles.close!,
		"roxum_files_open": HostFiles.open!,
		"roxum_files_open_root": HostFiles.open_root!,
		"roxum_files_send": HostFiles.send!,
		"roxum_instant_now_nanoseconds": HostInstant.now_nanoseconds!,
		"roxum_log_write": HostLog.write!,
		"roxum_random_u64": HostRandom.u64!,
		"roxum_rate_counter_add": HostRateCounter.add!,
		"roxum_rate_counter_new": HostRateCounter.new!,
		"roxum_secret_derive": HostSecret.derive!,
		"roxum_secret_from_env": HostSecret.from_env!,
		"roxum_secret_from_file": HostSecret.from_file!,
		"roxum_sleep_milliseconds": HostSleep.milliseconds!,
		"roxum_sleep_until": HostSleep.until_nanoseconds!,
		"roxum_stream_start": HostStream.start!,
		"roxum_stream_write": HostStream.write!,
		"roxum_tcp_acquire": HostTcp.acquire!,
		"roxum_tcp_acquire_origin": HostTcp.acquire_origin!,
		"roxum_tcp_check_ca": HostTcp.check_ca!,
		"roxum_tcp_close_scope": HostTcp.close_scope!,
		"roxum_tcp_configure_origins": HostTcp.configure_origins!,
		"roxum_tcp_discard": HostTcp.discard!,
		"roxum_tcp_is_new": HostTcp.is_new!,
		"roxum_tcp_open_scope": HostTcp.open_scope!,
		"roxum_tcp_pool": HostTcp.pool!,
		"roxum_tcp_read": HostTcp.read!,
		"roxum_tcp_release": HostTcp.release!,
		"roxum_tcp_scope_active": HostTcp.scope_active!,
		"roxum_tcp_start_tls": HostTcp.start_tls!,
		"roxum_tcp_write": HostTcp.write!,
		"roxum_tcp_write_derived": HostTcp.write_derived!,
		"roxum_time_now_unix_milliseconds": HostTime.now_unix_milliseconds!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: {
			inputs: ["libhost.a", app],
			output: Exe,
		},
		arm64musl: {
			inputs: ["crt1.o", "libhost.a", app, "libc.a"],
			output: Exe,
		},
		x64musl: {
			inputs: ["crt1.o", "libhost.a", app, "libc.a"],
			output: Exe,
		},
	}

import Http
import HeaderValue
import HttpError
import HostBody
import HostFile
import HostInstant
import HostLog
import HostRandom
import HostResponse
import HostRateCounter
import HostConcurrency
import HostSecret
import HostSleep
import HostStream
import HostTcp
import HostTime
import Instant
import Config
import File
import Log
import Handler
import Middleware
import Pipeline
import RequestHead
import BodyLimit
import Files
import FileRoot
import FileReply
import HostFiles
import Compression
import ContentCoding
import HostCompress
import Extract
import Extractor
import MethodRouter
import PathParam
import PathSegment
import QueryValue
import Random
import Reply
import RouteContext
import RouteError
import RouteProbe
import Routes
import Multipart
import MediaType
import JsonLines
import Redirect
import Path
import ContentDisposition
import MultipartBody
import UrlEncoded
import Router
import Respond
import RateCounter
import Concurrency
import Secret
import Sleep
import ResponseWriter
import Server
import Status
import Tcp
import Time

## The host keeps the initialized model as data, in a box, and hands it back
## with each request; `handle_for_host!` calls the top-level router directly.
## No function value crosses the host boundary, so the host does not call
## through Roc's erased-callable runtime. The host also gets the route
## patterns, which its metrics count requests by.
init_for_host! : {} => Try({ model : Box(Model), listen : Server.ListenOptions, routes : List(Str) }, [StartupErr(Str)])
init_for_host! = |{}|
	match (program.init!)({}) {
		Ok(application) => Ok({
			model: Box.box(application.model),
			listen: application.listen,
			routes: program.routes.route_patterns(),
		})
		Err(error) => Err(error)
	}

## Routes one request. The host gets the response and the route pattern that
## answered it, empty when none did, for its access log.
handle_for_host! : Box(Model), Http.Request => HostResponse
handle_for_host! = |model, request| {
	answered = program.routes.dispatch_with_route!(Box.unbox(model), request)
	route = match answered.route {
		Ok(pattern) => pattern
		Err(Unrouted) => ""
	}
	if !List.is_empty(answered.response.trailers) {
		match (Reply.writer(answered.reply), Reply.file_target(answered.reply)) {
			(Err(NotStreamed), Err(NotFile)) => {}
			_ => crash "Response trailers require a finite response"
		}
	}
	# A streamed body: send the head, then let the reply's function
	# write the body here, on the request's fiber. The host ends the body
	# once this returns; the response handed back is only its head.
	match Reply.writer(answered.reply) {
		Ok(written) => {
			(keep_alive_milliseconds, keep_alive_bytes) = match written.options.keep_alive {
				ResponseWriter.KeepAlive.None => (0, [])
				ResponseWriter.KeepAlive.Every({ milliseconds, bytes }) => (milliseconds, bytes)
			}
			# Compressed as it goes for `Compression.layer`.
			planned = match Reply.compression(answered.reply) {
				Ok(options) => Compression.plan(request, options, answered.response, Err(Unknown))
				Err(NotCompressible) => { headers: answered.response.headers, gzip: Bool.False }
			}
			head = { ..answered.response, headers: planned.headers }
			token = HostStream.start!(head, keep_alive_milliseconds, keep_alive_bytes, written.options.ends_on_drain, 18_446_744_073_709_551_615, planned.gzip)
			if token != 0 {
				write! = written.write!
				_ = write!(ResponseWriter.from_token(token))
			}
		}
		Err(NotStreamed) => {}
	}
	# A file: the platform opens it and sends it here. A body in
	# memory is compressed for `Compression.layer`.
	response = match Reply.file_target(answered.reply) {
		Ok(target) => FileReply.send!(request, answered.response, target, Reply.compression(answered.reply))
		Err(NotFile) =>
			match (Reply.writer(answered.reply), Reply.compression(answered.reply)) {
				(Err(NotStreamed), Ok(options)) => Compression.respond!(request, options, answered.response)
				_ => answered.response
			}
	}
	HostResponse.{ response, route }
}
