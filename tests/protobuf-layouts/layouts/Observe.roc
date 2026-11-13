import Graph
import Leaf

# Cross-module traversal exercises public nominal identities and Box/List payloads.
Observe := [].{
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
