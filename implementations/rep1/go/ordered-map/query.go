package orderedmap

// Min returns the smallest key. ok is false if the map is empty.
func (m *Map) Min() (key int64, ok bool) {
	n := m.root
	if n == nil {
		return 0, false
	}
	for n.left != nil {
		n = n.left
	}
	return n.key, true
}

// Max returns the largest key. ok is false if the map is empty.
func (m *Map) Max() (key int64, ok bool) {
	n := m.root
	if n == nil {
		return 0, false
	}
	for n.right != nil {
		n = n.right
	}
	return n.key, true
}

// Floor returns the largest key <= key.
func (m *Map) Floor(key int64) (int64, bool) {
	var best *node
	for n := m.root; n != nil; {
		switch {
		case key < n.key:
			n = n.left
		case key > n.key:
			best, n = n, n.right
		default:
			return n.key, true
		}
	}
	if best == nil {
		return 0, false
	}
	return best.key, true
}

// Ceil returns the smallest key >= key.
func (m *Map) Ceil(key int64) (int64, bool) {
	var best *node
	for n := m.root; n != nil; {
		switch {
		case key > n.key:
			n = n.right
		case key < n.key:
			best, n = n, n.left
		default:
			return n.key, true
		}
	}
	if best == nil {
		return 0, false
	}
	return best.key, true
}

// Successor returns the smallest key strictly greater than key.
// It never computes key+1, so it is safe at the extremes of int64.
func (m *Map) Successor(key int64) (int64, bool) {
	var best *node
	for n := m.root; n != nil; {
		if key < n.key {
			best, n = n, n.left
		} else {
			n = n.right
		}
	}
	if best == nil {
		return 0, false
	}
	return best.key, true
}

// Predecessor returns the largest key strictly less than key.
// It never computes key-1, so it is safe at the extremes of int64.
func (m *Map) Predecessor(key int64) (int64, bool) {
	var best *node
	for n := m.root; n != nil; {
		if key > n.key {
			best, n = n, n.right
		} else {
			n = n.left
		}
	}
	if best == nil {
		return 0, false
	}
	return best.key, true
}

// Rank returns the number of keys strictly less than key. The key need not
// be present.
func (m *Map) Rank(key int64) int {
	r := 0
	for n := m.root; n != nil; {
		if key <= n.key {
			n = n.left
		} else {
			r += int(size(n.left)) + 1
			n = n.right
		}
	}
	return r
}

// Select returns the k-th smallest key (0-based). ok is false if k is
// negative or k >= Len().
func (m *Map) Select(k int) (key int64, ok bool) {
	if k < 0 || k >= m.Len() {
		return 0, false
	}
	n := m.root
	for {
		ls := int(size(n.left))
		switch {
		case k < ls:
			n = n.left
		case k == ls:
			return n.key, true
		default:
			k -= ls + 1
			n = n.right
		}
	}
}
