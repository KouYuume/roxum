platform ""
	requires { main! : I64 => I64 }
	exposes [Host]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted { "roc_observe": Host.observe! }
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libhost.a", app], output: Exe },
	}

import Host

main_for_host! = |value| main!(value)
