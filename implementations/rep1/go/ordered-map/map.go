package orderedmap

// Map is an ordered map from int64 keys to string values.
// The zero value is an empty map ready to use.
type Map struct {
	root *node
}

// New returns an empty Map.
func New() *Map { return &Map{} }

// Len returns the number of keys in the map.
func (m *Map) Len() int { return int(size(m.root)) }

// Put associates value with key. It reports whether key was already
// present, in which case its previous value is replaced.
func (m *Map) Put(key int64, value string) (replaced bool) {
	m.root = insert(m.root, key, value, &replaced)
	return replaced
}

func insert(n *node, key int64, value string, replaced *bool) *node {
	if n == nil {
		return &node{key: key, value: value, height: 1, size: 1}
	}
	switch {
	case key < n.key:
		n.left = insert(n.left, key, value, replaced)
	case key > n.key:
		n.right = insert(n.right, key, value, replaced)
	default:
		n.value = value
		*replaced = true
		return n
	}
	if *replaced {
		return n // structure unchanged; no sizes or heights to fix
	}
	return rebalance(n)
}

// Delete removes key from the map and reports whether it was present.
func (m *Map) Delete(key int64) bool {
	var removed bool
	m.root = remove(m.root, key, &removed)
	return removed
}

func remove(n *node, key int64, removed *bool) *node {
	if n == nil {
		return nil
	}
	switch {
	case key < n.key:
		n.left = remove(n.left, key, removed)
	case key > n.key:
		n.right = remove(n.right, key, removed)
	default:
		*removed = true
		if n.left == nil {
			return n.right
		}
		if n.right == nil {
			return n.left
		}
		// Two children: replace with the in-order successor.
		var succ *node
		n.right, succ = removeMin(n.right)
		succ.left, succ.right = n.left, n.right
		return rebalance(succ)
	}
	if !*removed {
		return n
	}
	return rebalance(n)
}

// removeMin detaches the minimum node of the subtree rooted at n and
// returns the rebalanced remainder together with the detached node.
func removeMin(n *node) (rest, min *node) {
	if n.left == nil {
		return n.right, n
	}
	n.left, min = removeMin(n.left)
	return rebalance(n), min
}

// Get returns the value stored under key.
func (m *Map) Get(key int64) (value string, ok bool) {
	for n := m.root; n != nil; {
		switch {
		case key < n.key:
			n = n.left
		case key > n.key:
			n = n.right
		default:
			return n.value, true
		}
	}
	return "", false
}
