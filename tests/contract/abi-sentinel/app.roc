app [program] { pf: platform "./platform/main.roc" }

import pf.Choice
import pf.Probe

common_score : Probe -> U64
common_score = |probe| {
	code_score = if probe.code == 0x0102030405060708 {
		1
	} else {
		0
	}
	empty_score = if probe.empty == "" {
		2
	} else {
		0
	}
	short_score = if probe.short == "abcdefghijklmnopqrstuvw" {
		4
	} else {
		0
	}
	long_score = if probe.long == "abcdefghijklmnopqrstuvwx" {
		8
	} else {
		0
	}
	empty_list_score = if probe.list_empty == [] {
		16
	} else {
		0
	}
	one_list_score = if probe.list_one == [0xA5] {
		32
	} else {
		0
	}
	many_list_score = if probe.list_many == [0x11, 0x22, 0x33] {
		64
	} else {
		0
	}

	code_score + empty_score + short_score + long_score + empty_list_score + one_list_score + many_list_score
}

inspect : Probe -> U64
inspect = |probe| {
	choice_score = match probe.choice {
		Choice.Empty => 128
		Choice.Byte(value) => if value == 0xA5 {
			256
		} else {
			0
		}
		Choice.Pair(pair) => if pair.left == 0x1234 {
			if pair.right == 0x1112131415161718 {
				512
			} else {
				0
			}
		} else {
			0
		}
		Choice.Text(text) => if text == "abcdefghijklmnopqrstuvwx" {
			1024
		} else {
			0
		}
	}

	common_score(probe) + choice_score
}

produce : U8 -> Probe
produce = |case_id| {
	choice = match case_id {
		0 => Choice.Empty
		1 => Choice.Byte(0xA5)
		2 => Choice.Pair({ left: 0x1234, right: 0x1112131415161718 })
		_ => Choice.Text("abcdefghijklmnopqrstuvw${case_id.to_str()}")
	}

	Probe.{
		code: 0x0102030405060708,
		empty: "",
		short: "abcdefghijklmnopqrstuvw",
		long: "abcdefghijklmnopqrstuvw${case_id.to_str()}",
		list_empty: [],
		list_one: [case_id],
		list_many: [0x11, 0x22, case_id],
		choice,
	}
}

program = { inspect, produce }
