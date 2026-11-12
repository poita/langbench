package tessera

import "bytes"

// tree identifies one B+tree of the database: the primary tree (slot < 0) or
// the tree of an index directory slot. All trees use canonical pages and the
// algorithms of SPEC §12.
type tree struct {
	db   *DB
	slot int
}

func (db *DB) primary() tree        { return tree{db, -1} }
func (db *DB) indexTree(i int) tree { return tree{db, i} }

func (t tree) leafType() byte {
	if t.slot < 0 {
		return typeLeaf
	}
	return typeIndexLf
}

func (t tree) root() uint32 {
	if t.slot < 0 {
		return t.db.hdr.primaryRoot
	}
	return t.db.hdr.slots[t.slot].root
}

func (t tree) setRoot(r uint32) {
	if t.slot < 0 {
		t.db.hdr.primaryRoot = r
	} else {
		t.db.hdr.slots[t.slot].root = r
	}
}

// pathEnt is one step of a descent: an interior page, the node read from it
// and the child index taken (len(cells) meaning the rightmost child).
type pathEnt struct {
	pg  uint32
	n   *node
	idx int
}

// childIndex returns the smallest i with key <= k[i], or len(cells).
func childIndex(n *node, key []byte) int {
	lo, hi := 0, len(n.cells)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if bytes.Compare(key, n.cells[mid].key) <= 0 {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

func childAt(n *node, i int) uint32 {
	if i < len(n.cells) {
		return n.cells[i].child
	}
	return n.link
}

// leafSearch returns the position of the first cell with key >= the given key
// and whether that cell's key is equal.
func leafSearch(n *node, key []byte) (int, bool) {
	lo, hi := 0, len(n.cells)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if bytes.Compare(n.cells[mid].key, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(n.cells) && bytes.Equal(n.cells[lo].key, key)
}

// descend walks from the root to the leaf that would hold key. The root must
// be non-zero.
func (t tree) descend(key []byte) (path []pathEnt, leafPg uint32, leaf *node) {
	pg := t.root()
	for {
		n := t.db.readNode(pg)
		if n.typ != typeInterior {
			return path, pg, n
		}
		i := childIndex(n, key)
		path = append(path, pathEnt{pg, n, i})
		pg = childAt(n, i)
	}
}

// find looks up key in the tree.
func (t tree) find(key []byte) (cell, bool) {
	if t.root() == 0 {
		return cell{}, false
	}
	_, _, leaf := t.descend(key)
	i, ok := leafSearch(leaf, key)
	if !ok {
		return cell{}, false
	}
	return leaf.cells[i], true
}

// insert stores c, replacing any cell with the same key (SPEC §12.2). It
// reports whether a cell was replaced.
func (t tree) insert(c cell) (replaced bool) {
	if t.root() == 0 {
		r := t.db.allocPage()
		t.db.writeNode(r, &node{typ: t.leafType()})
		t.setRoot(r)
	}
	path, pg, leaf := t.descend(c.key)
	i, found := leafSearch(leaf, c.key)
	if found {
		leaf.cells[i] = c
	} else {
		leaf.cells = append(leaf.cells, cell{})
		copy(leaf.cells[i+1:], leaf.cells[i:])
		leaf.cells[i] = c
	}
	t.store(path, pg, leaf)
	return found
}

// splitPoint returns the smallest m in 1..n-1 with 2*P[m] >= T (SPEC §12.3).
func splitPoint(n *node) int {
	total := n.used()
	p := 0
	for m := 1; m < len(n.cells); m++ {
		p += n.cost(m - 1)
		if 2*p >= total {
			return m
		}
	}
	return len(n.cells) - 1
}

// store writes node n at page pg, splitting it, and its ancestors in turn, as
// long as a page overflows. path holds the ancestors of pg, nearest last.
func (t tree) store(path []pathEnt, pg uint32, n *node) {
	db := t.db
	for {
		if n.used() <= Capacity {
			db.writeNode(pg, n)
			return
		}
		m := splitPoint(n)
		rightPg := db.allocPage()
		right := &node{typ: n.typ, link: n.link}
		var sep []byte
		if n.typ == typeInterior {
			right.cells = append([]cell(nil), n.cells[m:]...)
			sep = n.cells[m-1].key
			n.link = n.cells[m-1].child
			n.cells = n.cells[: m-1 : m-1]
		} else {
			right.cells = append([]cell(nil), n.cells[m:]...)
			sep = n.cells[m-1].key
			n.link = rightPg
			n.cells = n.cells[:m:m]
		}
		db.writeNode(pg, n)
		db.writeNode(rightPg, right)
		if len(path) == 0 {
			root := db.allocPage()
			db.writeNode(root, &node{
				typ:   typeInterior,
				link:  rightPg,
				cells: []cell{{key: sep, child: pg}},
			})
			t.setRoot(root)
			return
		}
		pe := path[len(path)-1]
		path = path[:len(path)-1]
		parent := pe.n
		j := pe.idx
		if j == len(parent.cells) {
			parent.cells = append(parent.cells, cell{key: sep, child: pg})
			parent.link = rightPg
		} else {
			parent.cells[j].child = rightPg
			parent.cells = append(parent.cells, cell{})
			copy(parent.cells[j+1:], parent.cells[j:])
			parent.cells[j] = cell{key: sep, child: pg}
		}
		pg, n = pe.pg, parent
	}
}

// remove deletes the cell with the given key (SPEC §12.4, §12.5) and reports
// whether it existed.
func (t tree) remove(key []byte) bool {
	db := t.db
	if t.root() == 0 {
		return false
	}
	path, pg, leaf := t.descend(key)
	i, found := leafSearch(leaf, key)
	if !found {
		return false
	}
	leaf.cells = append(leaf.cells[:i:i], leaf.cells[i+1:]...)
	db.writeNode(pg, leaf)
	if len(path) == 0 {
		if len(leaf.cells) == 0 {
			db.freePage(pg)
			t.setRoot(0)
		}
		return true
	}
	if leaf.used() >= MinFill {
		return true
	}
	t.repair(path, pg, leaf)
	return true
}

// repair fixes the underflowing page pg (node n, already written) by borrowing
// from or merging with a sibling, propagating upward after merges.
func (t tree) repair(path []pathEnt, pg uint32, n *node) {
	db := t.db
	for {
		pe := path[len(path)-1]
		path = path[:len(path)-1]
		P, j := pe.n, pe.idx
		nP := len(P.cells)

		var lpg, rpg uint32
		var L, R *node
		if j >= 1 {
			lpg = P.cells[j-1].child
			L = db.readNode(lpg)
		}
		if j < nP {
			rpg = childAt(P, j+1)
			R = db.readNode(rpg)
		}
		interior := n.typ == typeInterior

		switch {
		case L != nil && L.used()-L.cost(len(L.cells)-1) >= MinFill:
			last := len(L.cells) - 1
			if interior {
				n.cells = append([]cell{{key: P.cells[j-1].key, child: L.link}}, n.cells...)
				P.cells[j-1].key = L.cells[last].key
				L.link = L.cells[last].child
				L.cells = L.cells[:last:last]
			} else {
				n.cells = append([]cell{L.cells[last]}, n.cells...)
				L.cells = L.cells[:last:last]
				P.cells[j-1].key = L.cells[last-1].key
			}
			db.writeNode(lpg, L)
			db.writeNode(pg, n)
			t.store(path, pe.pg, P)
			return

		case R != nil && R.used()-R.cost(0) >= MinFill:
			if interior {
				n.cells = append(n.cells[:len(n.cells):len(n.cells)], cell{key: P.cells[j].key, child: n.link})
				n.link = R.cells[0].child
				P.cells[j].key = R.cells[0].key
			} else {
				n.cells = append(n.cells[:len(n.cells):len(n.cells)], R.cells[0])
				P.cells[j].key = R.cells[0].key
			}
			R.cells = R.cells[1:len(R.cells):len(R.cells)]
			db.writeNode(rpg, R)
			db.writeNode(pg, n)
			t.store(path, pe.pg, P)
			return

		case L != nil:
			// Merge N into L; L survives, N is freed.
			cells := L.cells[:len(L.cells):len(L.cells)]
			if interior {
				cells = append(cells, cell{key: P.cells[j-1].key, child: L.link})
			}
			L.cells = append(cells, n.cells...)
			L.link = n.link
			db.writeNode(lpg, L)
			db.freePage(pg)
			P.cells = append(P.cells[:j-1:j-1], P.cells[j:]...)
			if j == nP {
				P.link = lpg
			} else {
				P.cells[j-1].child = lpg
			}

		default:
			// Merge R into N; N survives, R is freed.
			cells := n.cells[:len(n.cells):len(n.cells)]
			if interior {
				cells = append(cells, cell{key: P.cells[j].key, child: n.link})
			}
			n.cells = append(cells, R.cells...)
			n.link = R.link
			db.writeNode(pg, n)
			db.freePage(rpg)
			P.cells = append(P.cells[:j:j], P.cells[j+1:]...)
			if j+1 == nP {
				P.link = pg
			} else {
				P.cells[j].child = pg
			}
		}

		// A merge removed a cell from P.
		db.writeNode(pe.pg, P)
		if len(path) == 0 {
			if len(P.cells) == 0 {
				t.setRoot(P.link)
				db.freePage(pe.pg)
			}
			return
		}
		if P.used() >= MinFill {
			return
		}
		pg, n = pe.pg, P
	}
}

// ---------------------------------------------------------------------------
// Cursors and traversal

// walkFrom calls fn for each cell in ascending key order starting at the first
// key >= from (the beginning when from is nil), following the leaf chain,
// until fn returns false.
func (t tree) walkFrom(from []byte, fn func(c *cell) bool) {
	root := t.root()
	if root == 0 {
		return
	}
	var pg uint32
	var leaf *node
	pos := 0
	if from == nil {
		pg = root
		for {
			leaf = t.db.readNode(pg)
			if leaf.typ != typeInterior {
				break
			}
			pg = childAt(leaf, 0)
		}
	} else {
		_, pg, leaf = t.descend(from)
		pos, _ = leafSearch(leaf, from)
	}
	for {
		for ; pos < len(leaf.cells); pos++ {
			if !fn(&leaf.cells[pos]) {
				return
			}
		}
		if leaf.link == 0 {
			return
		}
		leaf = t.db.readNode(leaf.link)
		pos = 0
	}
}

// walkBackFrom calls fn for each cell in descending key order starting at the
// last key < before (the last key of the tree when before is nil) until fn
// returns false. Leaves have no back pointers, so the walk keeps the descent
// path and steps to the previous leaf through it.
func (t tree) walkBackFrom(before []byte, fn func(c *cell) bool) {
	root := t.root()
	if root == 0 {
		return
	}
	var path []pathEnt
	var leaf *node
	pos := 0
	if before == nil {
		pg := root
		for {
			n := t.db.readNode(pg)
			if n.typ != typeInterior {
				leaf = n
				pos = len(n.cells)
				break
			}
			path = append(path, pathEnt{pg, n, len(n.cells)})
			pg = n.link
		}
	} else {
		path, _, leaf = t.descend(before)
		pos, _ = leafSearch(leaf, before)
	}
	for {
		for pos--; pos >= 0; pos-- {
			if !fn(&leaf.cells[pos]) {
				return
			}
		}
		// Move to the previous leaf.
		for len(path) > 0 && path[len(path)-1].idx == 0 {
			path = path[:len(path)-1]
		}
		if len(path) == 0 {
			return
		}
		path[len(path)-1].idx--
		for {
			top := &path[len(path)-1]
			n := t.db.readNode(childAt(top.n, top.idx))
			if n.typ != typeInterior {
				leaf = n
				pos = len(n.cells)
				break
			}
			path = append(path, pathEnt{childAt(top.n, top.idx), n, len(n.cells)})
		}
	}
}

// freeTree frees every page of the tree rooted at pg in post-order and returns
// the number of pages freed (SPEC §12.6).
func (t tree) freeTree(pg uint32) int {
	n := t.db.readNode(pg)
	count := 0
	if n.typ == typeInterior {
		for i := range n.cells {
			count += t.freeTree(n.cells[i].child)
		}
		count += t.freeTree(n.link)
	}
	t.db.freePage(pg)
	return count + 1
}
