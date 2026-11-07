app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Handler
import Http
import MethodRouter
import PathParam
import Reply
import RouteProbe
import Router

Input := { path_case : U8, method_case : U8, order : U8 }.{
	generator_for = |_| {
		{ path_case: Fuzz.u8_in(0, 8), method_case: Fuzz.u8_in(0, 7), order: Fuzz.u8 }.Fuzz
	}
}

target = Fuzz.target({
	name: "roxum-router-resolution",
	test: |Input.{ path_case, method_case, order }| {
		actual = Router.probe(make_router(order), method_for(method_case), path_for(path_case))
		expected = oracle(path_case, method_case)
		if actual == expected { Fuzz.keep } else { crash "Router resolution differed from the linear oracle" }
	},
	show: |Input.{ path_case, method_case, order }| Str.inspect({ path_case, method_case, order }),
})

make_router = |order| {
	handler = Handler.static(|{}| Reply.full(Http.Response.{ status: 200, headers: [], body: Http.ResponseBody.Empty }))
	parameter_methods = MethodRouter.methods([MethodRouter.get(handler), MethodRouter.post(handler)])
	if order % 2 == 0 {
		Router.new
			.route("/users/{id}", parameter_methods)
			.route("/users/me", MethodRouter.get(handler))
			.route("/files/{*rest}", MethodRouter.get(handler))
			.route("/branch/static/x", MethodRouter.get(handler))
			.route("/branch/{id}/y", MethodRouter.get(handler))
	} else {
		Router.new
			.route("/files/{*rest}", MethodRouter.get(handler))
			.route("/users/me", MethodRouter.get(handler))
			.route("/users/{id}", parameter_methods)
			.route("/branch/{id}/y", MethodRouter.get(handler))
			.route("/branch/static/x", MethodRouter.get(handler))
	}
}

method_for = |choice|
	match choice {
		0 => Http.Method.OPTIONS
		1 => Http.Method.GET
		2 => Http.Method.HEAD
		3 => Http.Method.POST
		4 => Http.Method.PUT
		5 => Http.Method.DELETE
		6 => Http.Method.PATCH
		_ => Http.Method.QUERY
	}

path_for = |choice|
	match choice {
		0 => "/users/me"
		1 => "/users/a%2Fb"
		2 => "/files/a/b"
		3 => "/missing"
		4 => "/users/%FF"
		5 => "/files"
		6 => "/branch/static/y"
		# An encoded alias of `/users/me` and an encoded dot-dot capture.
		7 => "/users/%6De"
		_ => "/files/%2e%2e"
	}

oracle = |path_case, method_case|
	match path_case {
		0 | 7 => if method_case == 1 or method_case == 2 { RouteProbe.Found([]) } else { RouteProbe.MethodNotAllowed("GET, HEAD") }
		1 =>
			if method_case == 1 or method_case == 2 or method_case == 3 {
				RouteProbe.Found([PathParam.{ name: "id", value: "a/b" }])
			} else {
				RouteProbe.MethodNotAllowed("GET, HEAD, POST")
			}
		2 =>
			if method_case == 1 or method_case == 2 {
				RouteProbe.Found([PathParam.{ name: "rest", value: "a/b" }])
			} else {
				RouteProbe.MethodNotAllowed("GET, HEAD")
			}
		3 | 5 => RouteProbe.NotFound
		4 =>
			if method_case == 1 or method_case == 2 or method_case == 3 {
				RouteProbe.BadPathParams
			} else {
				RouteProbe.MethodNotAllowed("GET, HEAD, POST")
			}
		6 =>
			if method_case == 1 or method_case == 2 {
				RouteProbe.Found([PathParam.{ name: "id", value: "static" }])
			} else {
				RouteProbe.MethodNotAllowed("GET, HEAD")
			}
		_ => if method_case == 1 or method_case == 2 { RouteProbe.BadPathParams } else { RouteProbe.MethodNotAllowed("GET, HEAD") }
	}
