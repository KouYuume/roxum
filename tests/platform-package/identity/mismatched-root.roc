app [main] {
	pf: platform "./platform-b/main.roc",
	integration: "./integration/main.roc",
}

import integration.IdentityIntegration
import pf.Api

main : {} -> {}
main = |{}| {
	value : Api
	value = Api.new("ok")
	roundtrip : Api
	roundtrip = IdentityIntegration.roundtrip(value)
	_ = roundtrip
	{}
}
