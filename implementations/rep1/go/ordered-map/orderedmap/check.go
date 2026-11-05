package orderedmap

import "fmt"

// Validate checks the internal invariants (BST order, AVL balance, cached
// heights and sizes) and returns an error describing the first violation.
// It is intended for tests and debugging; it runs in O(n).
func (m *Map) Validate() error {
	if len(m.nodes) == 0 {
		return nil
	}
	if s := m.nodes[0]; s.size != 0 || s.height != 0 {
		return fmt.Errorf("sentinel modified: %+v", s)
	}
	_, _, err := m.validate(m.root, nil, nil)
	return err
}

func (m *Map) validate(i uint32, lo, hi *int64) (h int8, size uint32, err error) {
	if i == nilNode {
		return 0, 0, nil
	}
	n := m.nodes[i]
	if lo != nil && n.key <= *lo || hi != nil && n.key >= *hi {
		return 0, 0, fmt.Errorf("key %d violates BST order", n.key)
	}
	lh, ls, err := m.validate(n.left, lo, &n.key)
	if err != nil {
		return 0, 0, err
	}
	rh, rs, err := m.validate(n.right, &n.key, hi)
	if err != nil {
		return 0, 0, err
	}
	if d := lh - rh; d > 1 || d < -1 {
		return 0, 0, fmt.Errorf("node %d unbalanced (%d vs %d)", n.key, lh, rh)
	}
	h = lh
	if rh > h {
		h = rh
	}
	h++
	if n.height != h || n.size != ls+rs+1 {
		return 0, 0, fmt.Errorf("node %d has stale height/size", n.key)
	}
	return h, n.size, nil
}
