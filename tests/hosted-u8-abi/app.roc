app [main!] { pf: platform "platform/main.roc" }

import pf.Host

main! = |value| {
	Host.observe!(0, "zero")
	Host.observe!(1, "one")
	Host.observe!(2, "two")
	Host.observe!(3, "three")
	Host.observe!(1, "dynamic-${value.to_str()}")
	value
}
