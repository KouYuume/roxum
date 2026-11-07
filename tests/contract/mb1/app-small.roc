app [program] { pf: platform "./platform/main.roc" }

Model : { base : U64 }

program = {
	init: |{}| { base: 1000 },

	handle: |model, n| model.base + n,
}
