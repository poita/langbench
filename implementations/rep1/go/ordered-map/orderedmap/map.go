package orderedmap

// nil is the index of the sentinel node: size 0, height 0.
const nilNode = 0

type node struct {
	key         int64
	val         []byte
	left, right uint32
	size        uint32
	height      int8
}

// Map is an ordered map from int64 keys to []byte values.
// The zero value is an empty map ready to use.
type Map struct {
	nodes []node // nodes[0] is the sentinel
	root  uint32
	free  uint32 // head of the free list, linked through node.right
	// changed reports whether the last recursive mutation altered the tree
	// shape or size; when false the rebalancing on the way up is skipped.
	changed bool
}

// New returns an empty Map with room for capacity keys before the node pool
// has to grow.
func New(capacity int) *Map {
	if capacity < 0 {
		capacity = 0
	}
	m := &Map{}
	m.nodes = make([]node, 1, capacity+1)
	return m
}

// Len returns the number of keys in the map.
func (m *Map) Len() int {
	if len(m.nodes) == 0 {
		return 0
	}
	return int(m.nodes[m.root].size)
}

func (m *Map) init() {
	if len(m.nodes) == 0 {
		m.nodes = make([]node, 1, 16)
	}
}

func (m *Map) alloc(key int64, val []byte) uint32 {
	if m.free != nilNode {
		i := m.free
		m.free = m.nodes[i].right
		m.nodes[i] = node{key: key, val: val, size: 1, height: 1}
		return i
	}
	m.nodes = append(m.nodes, node{key: key, val: val, size: 1, height: 1})
	return uint32(len(m.nodes) - 1)
}

func (m *Map) release(i uint32) {
	m.nodes[i] = node{right: m.free}
	m.free = i
}

// update recomputes height and size of node i from its children.
func (m *Map) update(i uint32) {
	n := &m.nodes[i]
	l, r := &m.nodes[n.left], &m.nodes[n.right]
	h := l.height
	if r.height > h {
		h = r.height
	}
	n.height = h + 1
	n.size = l.size + r.size + 1
}

func (m *Map) rotateRight(i uint32) uint32 {
	l := m.nodes[i].left
	m.nodes[i].left = m.nodes[l].right
	m.nodes[l].right = i
	m.update(i)
	m.update(l)
	return l
}

func (m *Map) rotateLeft(i uint32) uint32 {
	r := m.nodes[i].right
	m.nodes[i].right = m.nodes[r].left
	m.nodes[r].left = i
	m.update(i)
	m.update(r)
	return r
}

// rebalance recomputes node i and applies the AVL rotations if needed,
// returning the new subtree root.
func (m *Map) rebalance(i uint32) uint32 {
	m.update(i)
	n := &m.nodes[i]
	bal := int(m.nodes[n.left].height) - int(m.nodes[n.right].height)
	switch {
	case bal > 1:
		l := n.left
		if m.nodes[m.nodes[l].left].height < m.nodes[m.nodes[l].right].height {
			n.left = m.rotateLeft(l)
		}
		return m.rotateRight(i)
	case bal < -1:
		r := n.right
		if m.nodes[m.nodes[r].right].height < m.nodes[m.nodes[r].left].height {
			n.right = m.rotateRight(r)
		}
		return m.rotateLeft(i)
	}
	return i
}

// Put associates val with key and reports whether the key was newly inserted
// (false means an existing value was replaced). The slice val is retained.
func (m *Map) Put(key int64, val []byte) (inserted bool) {
	m.init()
	m.changed = false
	m.root = m.put(m.root, key, val)
	return m.changed
}

func (m *Map) put(i uint32, key int64, val []byte) uint32 {
	if i == nilNode {
		m.changed = true
		return m.alloc(key, val)
	}
	n := &m.nodes[i]
	switch {
	case key < n.key:
		c := m.put(n.left, key, val)
		if !m.changed {
			return i
		}
		m.nodes[i].left = c
	case key > n.key:
		c := m.put(n.right, key, val)
		if !m.changed {
			return i
		}
		m.nodes[i].right = c
	default:
		n.val = val
		return i
	}
	return m.rebalance(i)
}

// Delete removes key and reports whether it was present.
func (m *Map) Delete(key int64) (deleted bool) {
	if m.Len() == 0 {
		return false
	}
	m.changed = false
	m.root = m.del(m.root, key)
	return m.changed
}

func (m *Map) del(i uint32, key int64) uint32 {
	if i == nilNode {
		return nilNode
	}
	n := &m.nodes[i]
	switch {
	case key < n.key:
		c := m.del(n.left, key)
		if !m.changed {
			return i
		}
		m.nodes[i].left = c
	case key > n.key:
		c := m.del(n.right, key)
		if !m.changed {
			return i
		}
		m.nodes[i].right = c
	default:
		m.changed = true
		if n.left == nilNode || n.right == nilNode {
			c := n.left
			if c == nilNode {
				c = n.right
			}
			m.release(i)
			return c
		}
		// Two children: take the in-order successor's key and value.
		r, min := m.delMin(n.right)
		n = &m.nodes[i]
		n.key, n.val = m.nodes[min].key, m.nodes[min].val
		n.right = r
		m.release(min)
	}
	return m.rebalance(i)
}

// delMin detaches the leftmost node of the subtree rooted at i. It returns the
// new subtree root and the detached node (not yet released).
func (m *Map) delMin(i uint32) (root, min uint32) {
	n := &m.nodes[i]
	if n.left == nilNode {
		return n.right, i
	}
	c, min := m.delMin(n.left)
	m.nodes[i].left = c
	return m.rebalance(i), min
}
