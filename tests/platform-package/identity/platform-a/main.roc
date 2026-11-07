platform "m9p-identity"
	requires {
		main : {} -> {}
	}
	exposes [Api]
	packages {}
	provides { "roc_main": main_for_host }

import Api

main_for_host : {} -> {}
main_for_host = |{}| main({})
