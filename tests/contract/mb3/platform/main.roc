# Returning a heap-backed string exercises allocation under the active request context.
platform "req-ctx-contract"
	requires {
		[Model : model] for program : {
			init : {} -> model,
			handle : model, U64 -> Str,
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

handle_for_host : Box(Model), U64 -> Str
handle_for_host = |boxed_model, n| {
	model = Box.unbox(boxed_model)
	(program.handle)(model, n)
}
