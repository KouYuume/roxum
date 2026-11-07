app [program] { pf: platform "./platform/main.roc" }

Model : { base : U64 }

program = {
	init: |{}| { base: 1000 },

	handle: |model, n| "request-${(model.base + n).to_str()}-payload-padding-to-force-heap-allocation",
}
