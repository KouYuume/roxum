import Leaf

# Handwritten type-layout candidates, not generated codecs.
Graph := [].{
	Node := { value : U64, leaf : Leaf, next : [Absent, Present(Box(Node))] }
	Left := { value : U64, leaf : Leaf, right : [Absent, Present(Box(Right))] }
	Right := { value : U64, leaf : Leaf, left : [Absent, Present(Box(Left))] }
	Tree := { value : U64, leaf : Leaf, children : List(Tree) }

	node : U64, U64, Leaf -> Node
	node = |depth, seed, leaf| {
		var $node = Node.{ value: seed, leaf, next: Absent }
		var $index = 0.U64
		while $index < depth {
			$index = $index + 1
			$node = Node.{ value: seed + $index, leaf, next: Present(Box.box($node)) }
		}
		$node
	}

	left : U64, U64, Leaf -> Left
	left = |depth, seed, leaf| Left.{
		value: seed + depth,
		leaf,
		right: if depth == 0 {
			Absent
		} else {
			Present(Box.box(right(depth - 1, seed, leaf)))
		},
	}

	right : U64, U64, Leaf -> Right
	right = |depth, seed, leaf| Right.{
		value: seed + depth,
		leaf,
		left: if depth == 0 {
			Absent
		} else {
			Present(Box.box(left(depth - 1, seed, leaf)))
		},
	}

	# Each level retains the same terminal value beside the growing branch.
	# The number of logical nodes grows linearly, not exponentially with depth.
	tree : U64, U64, Leaf -> Tree
	tree = |depth, seed, leaf| {
		terminal = Tree.{ value: seed, leaf, children: [] }
		var $tree = terminal
		var $index = 0.U64
		while $index < depth {
			$index = $index + 1
			$tree = Tree.{ value: seed + $index, leaf, children: [$tree, terminal] }
		}
		$tree
	}
}
