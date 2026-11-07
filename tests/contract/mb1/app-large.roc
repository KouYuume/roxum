app [program] { pf: platform "./platform/main.roc" }
Model : {
	base : U64,
	name : Str,
	tags : List(Str),
	numbers : List(U64),
}

program = {
	init: |{}| {
		base: 1000,
		name: "a moderately long model name for the spike",
		tags: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"],
		numbers: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
	},

	handle: |model, n| model.base + n + List.len(model.tags) + List.len(model.numbers),
}
