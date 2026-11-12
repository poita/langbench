package orderedmap

// Range calls fn for each entry with lo <= key <= hi in ascending key
// order, stopping early if fn returns false. It runs in O(log n + r) where
// r is the number of entries visited. fn must not modify the map.
func (m *Map) Range(lo, hi int64, fn func(key int64, value string) bool) {
	if lo > hi {
		return
	}
	walk(m.root, lo, hi, fn)
}

// walk is an in-order traversal pruned to [lo, hi]. It returns false once
// fn has asked to stop.
func walk(n *node, lo, hi int64, fn func(int64, string) bool) bool {
	for n != nil {
		if n.key < lo {
			n = n.right
			continue
		}
		if n.key > hi {
			n = n.left
			continue
		}
		if !walk(n.left, lo, hi, fn) || !fn(n.key, n.value) {
			return false
		}
		n = n.right
	}
	return true
}

// Ascend calls fn for every entry in ascending key order, stopping early if
// fn returns false.
func (m *Map) Ascend(fn func(key int64, value string) bool) {
	m.Range(-1<<63, 1<<63-1, fn)
}
