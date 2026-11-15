import Graph
import Leaf
import Maps
import Status

# Cross-module traversal exercises public nominal identities and Box/List payloads.
Observe := [].{
	# Iterate and look up from a separate module; do not rely on Dict order.
	maps : Maps -> Str
	maps = |Maps.(record)| {
		var $lines = []
		for (key, value) in record.signed32 {
			lookup = match Dict.get(record.signed32, key) {
				Ok(found) => map_leaf(found)
				Err(_) => "missing"
			}
			key_text = key.to_str()
			$lines = $lines.append("signed32:${key_text}=${map_leaf(value)}~${lookup}")
		}
		for (key, value) in record.signed64 {
			lookup = match Dict.get(record.signed64, key) {
				Ok(found) => map_status(found)
				Err(_) => "missing"
			}
			key_text = key.to_str()
			$lines = $lines.append("signed64:${key_text}=${map_status(value)}~${lookup}")
		}
		for (key, value) in record.unsigned32 {
			lookup = match Dict.get(record.unsigned32, key) {
				Ok(found) => map_bytes(found)
				Err(_) => "missing"
			}
			key_text = key.to_str()
			$lines = $lines.append("unsigned32:${key_text}=${map_bytes(value)}~${lookup}")
		}
		for (key, value) in record.unsigned64 {
			lookup = match Dict.get(record.unsigned64, key) {
				Ok(found) => map_text(found)
				Err(_) => "missing"
			}
			key_text = key.to_str()
			$lines = $lines.append("unsigned64:${key_text}=${map_text(value)}~${lookup}")
		}
		for (key, value) in record.flags {
			lookup = match Dict.get(record.flags, key) {
				Ok(found) => map_leaf(found)
				Err(_) => "missing"
			}
			key_text = if key { "true" } else { "false" }
			$lines = $lines.append("flags:${key_text}=${map_leaf(value)}~${lookup}")
		}
		for (key, value) in record.strings {
			lookup = match Dict.get(record.strings, key) {
				Ok(found) => map_leaf(found)
				Err(_) => "missing"
			}
			key_text = key
			$lines = $lines.append("strings:${key_text}=${map_leaf(value)}~${lookup}")
		}
		Str.join_with($lines, "\n")
	}

	Stats : { nodes : U64, sum : U64, bytes : U64 }

	node : Graph.Node -> Stats
	node = |Graph.Node.(record)| {
		own = one(record.value, record.leaf)
		match record.next {
			Absent => own
			Present(child) => add(own, node(Box.unbox(child)))
		}
	}

	left : Graph.Left -> Stats
	left = |Graph.Left.(record)| {
		own = one(record.value, record.leaf)
		match record.right {
			Absent => own
			Present(child) => add(own, right(Box.unbox(child)))
		}
	}

	right : Graph.Right -> Stats
	right = |Graph.Right.(record)| {
		own = one(record.value, record.leaf)
		match record.left {
			Absent => own
			Present(child) => add(own, left(Box.unbox(child)))
		}
	}

	tree : Graph.Tree -> Stats
	tree = |Graph.Tree.(record)| {
		var $stats = one(record.value, record.leaf)
		for child in record.children {
			$stats = add($stats, tree(child))
		}
		$stats
	}
}

one : U64, Leaf -> Observe.Stats
one = |value, Leaf.(leaf)| {
	var $sum = value
	for byte in leaf.payload {
		$sum = $sum + byte.to_u64()
	}
	{ nodes: 1, sum: $sum, bytes: Str.count_utf8_bytes(leaf.text) + leaf.payload.len() }
}

add : Observe.Stats, Observe.Stats -> Observe.Stats
add = |left, right| { nodes: left.nodes + right.nodes, sum: left.sum + right.sum, bytes: left.bytes + right.bytes }

map_leaf = |Leaf.(record)| "${record.text}/${map_bytes(record.payload)}"

map_status = |value| Status.to_number(value).to_str()

map_bytes = |bytes| Str.join_with(bytes.map(|byte| byte.to_str()), ",")

map_text = |text| text
