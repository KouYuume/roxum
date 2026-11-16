import Leaf
import Status

# Preserve declared map key types, including widths that share a wire encoding.
Maps := {
	signed32 : Dict(I32, Leaf),
	signed64 : Dict(I64, Status),
	unsigned32 : Dict(U32, List(U8)),
	unsigned64 : Dict(U64, Str),
	flags : Dict(Bool, Leaf),
	strings : Dict(Str, Leaf),
}.{
	new : List(U64) -> Maps
	new = |keys| {
		var $signed32 = Dict.empty()
		var $signed64 = Dict.empty()
		var $unsigned32 = Dict.empty()
		var $unsigned64 = Dict.empty()
		var $flags = Dict.empty()
		var $strings = Dict.empty()
		var $index = 0.U64
		for raw in keys {
			text = "map payload ${raw.to_str()} at ${$index.to_str()} 🐦"
			payload = [raw.to_u8_wrap(), $index.to_u8_wrap(), 255]
			leaf = Leaf.{ text, payload }
			$signed32 = Dict.insert($signed32, raw.to_i32_wrap(), leaf)
			$signed64 = Dict.insert($signed64, raw.to_i64_wrap(), Status.from_number(raw.to_i32_wrap()))
			$unsigned32 = Dict.insert($unsigned32, raw.to_u32_wrap(), payload)
			$unsigned64 = Dict.insert($unsigned64, raw, text)
			$flags = Dict.insert($flags, raw % 2 == 1, leaf)
			$strings = Dict.insert($strings, string_key(raw), leaf)
			$index = $index + 1
		}
		Maps.{
			signed32: $signed32,
			signed64: $signed64,
			unsigned32: $unsigned32,
			unsigned64: $unsigned64,
			flags: $flags,
			strings: $strings,
		}
	}

	# Replace an entire value while a caller retains the original dictionaries.
	replace : Maps, U64 -> Maps
	replace = |Maps.(record), raw| {
		replacement = Leaf.{ text: "replacement", payload: [] }
		Maps.{
			signed32: Dict.insert(record.signed32, raw.to_i32_wrap(), replacement),
			signed64: Dict.insert(record.signed64, raw.to_i64_wrap(), Status.unspecified),
			unsigned32: Dict.insert(record.unsigned32, raw.to_u32_wrap(), []),
			unsigned64: Dict.insert(record.unsigned64, raw, ""),
			flags: Dict.insert(record.flags, raw % 2 == 1, replacement),
			strings: Dict.insert(record.strings, string_key(raw), replacement),
		}
	}
}

string_key : U64 -> Str
string_key = |raw| if raw == 0 { "" } else { "map key ${raw.to_str()} with heap storage 🐦" }
