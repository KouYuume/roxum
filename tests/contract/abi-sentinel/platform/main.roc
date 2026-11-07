platform "abi-sentinel"
	requires {
		program : {
			inspect : Abi.Probe -> U64,
			produce : U8 -> Abi.Probe,
		}
	}
	exposes [Abi.Probe, Abi.Choice]
	packages {}
	provides {
		"roc_inspect": inspect_for_host,
		"roc_produce": produce_for_host,
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

import Abi

inspect_for_host : Abi.Probe -> U64
inspect_for_host = |probe| (program.inspect)(probe)

produce_for_host : U8 -> Abi.Probe
produce_for_host = |case_id| (program.produce)(case_id)
