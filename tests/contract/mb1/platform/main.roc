# Box.unbox consumes its argument; the host must retain the root for each invocation.
platform "box-model-contract"
	requires {
		[Model : model] for program : {
			init : {} -> model,
			handle : model, U64 -> U64,
		}
	}
	exposes []
	packages {}
	provides {
		"roc_init": init_for_host,
		"roc_handle": handle_for_host,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libhost.a", app], output: Exe },
	}

init_for_host : {} -> Box(Model)
init_for_host = |{}| Box.box((program.init)({}))

handle_for_host : Box(Model), U64 -> U64
handle_for_host = |boxed_model, n| {
	model = Box.unbox(boxed_model)
	(program.handle)(model, n)
}
