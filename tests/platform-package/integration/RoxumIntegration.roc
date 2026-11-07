import pf.HeaderName
import pf.HeaderValue
import pf.Log
import pf.Response
import pf.ResponseHeader

RoxumIntegration :: [].{
	mark : Response -> Response
	mark = |response| {
		value : HeaderValue
		value = "m9p1"
		header = ResponseHeader.{
			name: HeaderName.("x-roxum-integration"),
			value,
		}
		{ ..response, headers: List.concat(response.headers, [header]) }
	}

	log_response! : Response => Response
	log_response! = |response| {
		Log.info!("m9p1")
		response
	}
}
