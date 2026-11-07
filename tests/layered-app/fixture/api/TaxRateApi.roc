import hc.HttpClient
import http.Method
import http.Request
import pf.Log
import pf.Secret

## The adapter for the outbound tax-rate service: `GET {url}` with a bearer
## token answers `{"rate_percent": 10}`. The token stays in the host (a
## `Secret` read from `tax.token_file`); a failed call reaches the core only
## as `Unavailable`, and the log says what failed, never the token.
TaxRateApi := { client : HttpClient.Client, url : Str, token : Secret }.{
	new : HttpClient.Client, Str, Secret -> TaxRateApi
	new = |client, url, token| { client: client, url: url, token: token }

	rate! : TaxRateApi => Try(U64, [Unavailable])
	rate! = |api| {
		request = Request.from_method(Method.GET)
			.with_uri(api.url)
			.add_header("Accept", "application/json")
			.with_timeout(TimeoutMilliseconds(2_000))
		sent = HttpClient.send_with!(
			api.client,
			request,
			HttpClient.SendOptions.{ secret_headers: [{ name: "Authorization", prefix: "Bearer ", secret: api.token }] },
		)
		response = match sent {
			Ok(answer) => answer
			Err(HttpClientTimedOut) => return unavailable!("tax: the tax-rate service did not answer in time")
			Err(_) => return unavailable!("tax: the tax-rate request failed")
		}
		if response.status() != 200 {
			return unavailable!("tax: the tax-rate service answered ${response.status().to_str()}")
		}
		body : Try({ rate_percent : U64 }, _)
		body = Encoding.Json.parse(Str.from_utf8_lossy(response.body()))
		match body {
			Ok({ rate_percent }) => Ok(rate_percent)
			Err(_) => unavailable!("tax: the tax-rate service answered something other than a rate")
		}
	}
}

unavailable! : Str => Try(U64, [Unavailable])
unavailable! = |message| {
	Log.error!(message)
	Err(Unavailable)
}
