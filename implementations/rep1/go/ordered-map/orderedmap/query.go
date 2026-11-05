package orderedmap

// Get returns the value stored under key.
func (m *Map) Get(key int64) (val []byte, ok bool) {
	if len(m.nodes) == 0 {
		return nil, false
	}
	for i := m.root; i != nilNode; {
		n := &m.nodes[i]
		switch {
		case key < n.key:
			i = n.left
		case key > n.key:
			i = n.right
		default:
			return n.val, true
		}
	}
	return nil, false
}

// Min returns the smallest key.
func (m *Map) Min() (key int64, ok bool) {
	if m.Len() == 0 {
		return 0, false
	}
	i := m.root
	for m.nodes[i].left != nilNode {
		i = m.nodes[i].left
	}
	return m.nodes[i].key, true
}

// Max returns the largest key.
func (m *Map) Max() (key int64, ok bool) {
	if m.Len() == 0 {
		return 0, false
	}
	i := m.root
	for m.nodes[i].right != nilNode {
		i = m.nodes[i].right
	}
	return m.nodes[i].key, true
}

// Floor returns the largest key <= key.
func (m *Map) Floor(key int64) (int64, bool) { return m.below(key, true) }

// Predecessor returns the largest key < key.
func (m *Map) Predecessor(key int64) (int64, bool) { return m.below(key, false) }

// Ceil returns the smallest key >= key.
func (m *Map) Ceil(key int64) (int64, bool) { return m.above(key, true) }

// Successor returns the smallest key > key.
func (m *Map) Successor(key int64) (int64, bool) { return m.above(key, false) }

// below finds the largest key < key (or <= key when inclusive). It only
// compares keys, so it is safe at the int64 extremes.
func (m *Map) below(key int64, inclusive bool) (best int64, ok bool) {
	if m.Len() == 0 {
		return 0, false
	}
	for i := m.root; i != nilNode; {
		n := &m.nodes[i]
		if n.key < key || (inclusive && n.key == key) {
			best, ok = n.key, true
			i = n.right
		} else {
			i = n.left
		}
	}
	return best, ok
}

// above finds the smallest key > key (or >= key when inclusive).
func (m *Map) above(key int64, inclusive bool) (best int64, ok bool) {
	if m.Len() == 0 {
		return 0, false
	}
	for i := m.root; i != nilNode; {
		n := &m.nodes[i]
		if n.key > key || (inclusive && n.key == key) {
			best, ok = n.key, true
			i = n.left
		} else {
			i = n.right
		}
	}
	return best, ok
}

// Rank returns the number of keys strictly less than key. key need not be
// present.
func (m *Map) Rank(key int64) int {
	if m.Len() == 0 {
		return 0
	}
	rank := 0
	for i := m.root; i != nilNode; {
		n := &m.nodes[i]
		if key > n.key {
			rank += int(m.nodes[n.left].size) + 1
			i = n.right
		} else {
			i = n.left
		}
	}
	return rank
}

// Select returns the k-th smallest key (0-based). ok is false if k is
// negative or k >= Len().
func (m *Map) Select(k int) (key int64, ok bool) {
	if k < 0 || k >= m.Len() {
		return 0, false
	}
	i := m.root
	for {
		n := &m.nodes[i]
		ls := int(m.nodes[n.left].size)
		switch {
		case k < ls:
			i = n.left
		case k == ls:
			return n.key, true
		default:
			k -= ls + 1
			i = n.right
		}
	}
}

// Ascend calls fn for every entry with lo <= key <= hi in ascending key
// order, stopping early if fn returns false. It does nothing if lo > hi. The
// map must not be modified during the traversal.
func (m *Map) Ascend(lo, hi int64, fn func(key int64, val []byte) bool) {
	if lo > hi || m.Len() == 0 {
		return
	}
	m.ascend(m.root, lo, hi, fn)
}

func (m *Map) ascend(i uint32, lo, hi int64, fn func(int64, []byte) bool) bool {
	for i != nilNode {
		n := &m.nodes[i]
		if n.key > lo && !m.ascend(n.left, lo, hi, fn) {
			return false
		}
		if n.key >= lo && n.key <= hi && !fn(n.key, n.val) {
			return false
		}
		if n.key >= hi {
			return true
		}
		i = n.right
	}
	return true
}
