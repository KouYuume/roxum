import Http

## What the platform hands the host for each request: the response, and the
## route pattern that answered it (`Router.dispatch_with_route!`), empty when
## none did, for the access log. Not part of the app's API.
HostResponse := {
	response : Http.Response,
	route : Str,
}
