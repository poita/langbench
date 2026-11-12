package orderbook

// The functions in this file implement a treap of levels keyed by price. The
// levels themselves are the nodes (see level), so the tree allocates nothing.

func rotateRight(t *level) *level {
	l := t.left
	t.left = l.right
	l.right = t
	return l
}

func rotateLeft(t *level) *level {
	r := t.right
	t.right = r.left
	r.left = t
	return r
}

// treeInsert inserts n, whose price must not already be in the tree.
func treeInsert(t, n *level) *level {
	if t == nil {
		return n
	}
	if n.price < t.price {
		t.left = treeInsert(t.left, n)
		if t.left.prio > t.prio {
			t = rotateRight(t)
		}
	} else {
		t.right = treeInsert(t.right, n)
		if t.right.prio > t.prio {
			t = rotateLeft(t)
		}
	}
	return t
}

func treeMerge(a, b *level) *level {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	if a.prio > b.prio {
		a.right = treeMerge(a.right, b)
		return a
	}
	b.left = treeMerge(a, b.left)
	return b
}

// treeDelete removes the node with the given price, if present.
func treeDelete(t *level, price uint64) *level {
	if t == nil {
		return nil
	}
	switch {
	case price < t.price:
		t.left = treeDelete(t.left, price)
	case price > t.price:
		t.right = treeDelete(t.right, price)
	default:
		m := treeMerge(t.left, t.right)
		t.left, t.right = nil, nil
		return m
	}
	return t
}

func treeMin(t *level) *level {
	if t == nil {
		return nil
	}
	for t.left != nil {
		t = t.left
	}
	return t
}

func treeMax(t *level) *level {
	if t == nil {
		return nil
	}
	for t.right != nil {
		t = t.right
	}
	return t
}

// treeWalk visits levels in ascending (or, if desc, descending) price order
// until fn returns false. It reports whether the walk ran to completion.
func treeWalk(t *level, desc bool, fn func(*level) bool) bool {
	if t == nil {
		return true
	}
	first, second := t.left, t.right
	if desc {
		first, second = second, first
	}
	return treeWalk(first, desc, fn) && fn(t) && treeWalk(second, desc, fn)
}
