package orderedmap

// node is an AVL tree node augmented with the size of its subtree.
type node struct {
	key         int64
	value       string
	left, right *node
	height      int32 // height of the subtree rooted here; a leaf has height 1
	size        int32 // number of keys in the subtree rooted here
}

func height(n *node) int32 {
	if n == nil {
		return 0
	}
	return n.height
}

func size(n *node) int32 {
	if n == nil {
		return 0
	}
	return n.size
}

// update recomputes the cached height and size of n from its children.
func (n *node) update() {
	hl, hr := height(n.left), height(n.right)
	if hl > hr {
		n.height = hl + 1
	} else {
		n.height = hr + 1
	}
	n.size = size(n.left) + size(n.right) + 1
}

func rotateRight(n *node) *node {
	l := n.left
	n.left = l.right
	l.right = n
	n.update()
	l.update()
	return l
}

func rotateLeft(n *node) *node {
	r := n.right
	n.right = r.left
	r.left = n
	n.update()
	r.update()
	return r
}

// rebalance refreshes n's cached fields and restores the AVL invariant
// (child heights differ by at most one), returning the new subtree root.
func rebalance(n *node) *node {
	n.update()
	switch bal := height(n.left) - height(n.right); {
	case bal > 1:
		if height(n.left.left) < height(n.left.right) {
			n.left = rotateLeft(n.left)
		}
		return rotateRight(n)
	case bal < -1:
		if height(n.right.right) < height(n.right.left) {
			n.right = rotateRight(n.right)
		}
		return rotateLeft(n)
	}
	return n
}
