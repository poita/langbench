package engine

import (
	"bytes"
)

// tree is a B+tree in the pager: the primary tree (leaf type typeLeaf) or an
// index tree (typeIdxLeaf). root points at the tree's root field, which lives
// in the header.
type tree struct {
	p    *pager
	leaf byte
	root *uint32
}

// step is one level of a descent: an interior page, its decoded node, and the
// child index taken.
type step struct {
	page uint32
	n    *node
	idx  int
}

// findLeaf descends to the leaf that would hold key and returns its image,
// or nil for an empty tree.
func (t *tree) findLeaf(key []byte) []byte {
	if *t.root == 0 {
		return nil
	}
	img := t.p.read(*t.root)
	for img[0] == typeInterior {
		i := lowerBound(img, key)
		var next uint32
		if i < pageCellCount(img) {
			next = rawChild(img, i)
		} else {
			next = pageLink(img)
		}
		img = t.p.read(next)
	}
	return img
}

// lookup finds an exact key and returns its leaf image and cell index.
func (t *tree) lookup(key []byte) (img []byte, idx int, ok bool) {
	img = t.findLeaf(key)
	if img == nil {
		return nil, 0, false
	}
	i := lowerBound(img, key)
	if i < pageCellCount(img) && bytes.Equal(rawKey(img, i), key) {
		return img, i, true
	}
	return img, i, false
}

// cursor walks the leaf chain in key order.
type cursor struct {
	t   *tree
	img []byte
	i   int
}

// seek positions a cursor at the first entry whose key is >= key (an empty or
// nil key selects the very first entry).
func (t *tree) seek(key []byte) cursor {
	img := t.findLeaf(key)
	c := cursor{t: t, img: img}
	if img != nil {
		c.i = lowerBound(img, key)
		c.settle()
	}
	return c
}

// settle moves to the next leaf while the cursor is past the end of its page.
func (c *cursor) settle() {
	for c.img != nil && c.i >= pageCellCount(c.img) {
		next := pageLink(c.img)
		if next == 0 {
			c.img = nil
			return
		}
		c.img = c.t.p.read(next)
		c.i = 0
	}
}

func (c *cursor) valid() bool  { return c.img != nil }
func (c *cursor) key() []byte  { return rawKey(c.img, c.i) }
func (c *cursor) next()        { c.i++; c.settle() }
func (c *cursor) cellIdx() int { return c.i }

// descend walks to the leaf for key, recording the path of interior nodes.
func (t *tree) descend(key []byte) (path []step, page uint32, leaf *node) {
	page = *t.root
	for {
		n := decodeNode(t.p.read(page))
		if n.isLeaf() {
			return path, page, n
		}
		img := t.p.read(page)
		i := lowerBound(img, key)
		var next uint32
		if i < len(n.cells) {
			next = n.cells[i].child
		} else {
			next = n.link
		}
		path = append(path, step{page, n, i})
		page = next
	}
}

// insert stores c, replacing the existing cell with the same key if any.
func (t *tree) insert(c cell) {
	p := t.p
	if *t.root == 0 {
		r := p.alloc()
		empty := node{typ: t.leaf}
		p.write(r, empty.encode())
		*t.root = r
	}
	path, page, leaf := t.descend(c.key)
	i := 0
	for i < len(leaf.cells) && bytes.Compare(leaf.cells[i].key, c.key) < 0 {
		i++
	}
	if i < len(leaf.cells) && bytes.Equal(leaf.cells[i].key, c.key) {
		leaf.cells[i] = c
	} else {
		leaf.cells = append(leaf.cells, cell{})
		copy(leaf.cells[i+1:], leaf.cells[i:])
		leaf.cells[i] = c
	}
	t.store(path, page, leaf)
}

// store writes node n to page, splitting it (and, in turn, its parents) while
// it overflows. path holds the interior ancestors of page.
func (t *tree) store(path []step, page uint32, n *node) {
	p := t.p
	for {
		if n.used() <= Capacity {
			p.write(page, n.encode())
			return
		}
		m := n.splitPoint()
		right := p.alloc()
		rn := &node{typ: n.typ, link: n.link}
		var sep []byte
		if n.isLeaf() {
			rn.cells = append([]cell(nil), n.cells[m:]...)
			n.link = right
			sep = n.cells[m-1].key
			n.cells = n.cells[:m:m]
		} else {
			rn.cells = append([]cell(nil), n.cells[m:]...)
			n.link = n.cells[m-1].child
			sep = n.cells[m-1].key
			n.cells = n.cells[: m-1 : m-1]
		}
		p.write(page, n.encode())
		p.write(right, rn.encode())
		if len(path) == 0 {
			nr := p.alloc()
			root := &node{typ: typeInterior, link: right, cells: []cell{{key: sep, child: page}}}
			p.write(nr, root.encode())
			*t.root = nr
			return
		}
		st := path[len(path)-1]
		path = path[:len(path)-1]
		parent := st.n
		if st.idx == len(parent.cells) {
			parent.cells = append(parent.cells, cell{key: sep, child: page})
			parent.link = right
		} else {
			parent.cells[st.idx].child = right
			parent.cells = append(parent.cells, cell{})
			copy(parent.cells[st.idx+1:], parent.cells[st.idx:])
			parent.cells[st.idx] = cell{key: sep, child: page}
		}
		page, n = st.page, parent
	}
}

// remove deletes key and reports whether it was present.
func (t *tree) remove(key []byte) bool {
	if *t.root == 0 {
		return false
	}
	p := t.p
	path, page, leaf := t.descend(key)
	i := 0
	for i < len(leaf.cells) && bytes.Compare(leaf.cells[i].key, key) < 0 {
		i++
	}
	if i >= len(leaf.cells) || !bytes.Equal(leaf.cells[i].key, key) {
		return false
	}
	leaf.cells = append(leaf.cells[:i], leaf.cells[i+1:]...)
	if len(path) == 0 {
		if len(leaf.cells) > 0 {
			p.write(page, leaf.encode())
		} else {
			p.free(page)
			*t.root = 0
		}
		return true
	}
	p.write(page, leaf.encode())
	if leaf.used() >= MinFill {
		return true
	}
	t.underflow(path, page, leaf)
	return true
}

func (t *tree) load(page uint32) *node { return decodeNode(t.p.read(page)) }

// underflow repairs an underflowing node n (on page) by borrowing from or
// merging with a sibling, climbing while merges leave the parent thin.
func (t *tree) underflow(path []step, page uint32, n *node) {
	p := t.p
	for {
		st := path[len(path)-1]
		path = path[:len(path)-1]
		par := st.n
		j := st.idx
		np := len(par.cells)

		var lpage, rpage uint32
		var l, r *node
		if j >= 1 {
			lpage = par.cells[j-1].child
			l = t.load(lpage)
		}
		if j < np {
			if j+1 < np {
				rpage = par.cells[j+1].child
			} else {
				rpage = par.link
			}
			r = t.load(rpage)
		}

		switch {
		case l != nil && l.used()-l.cost(len(l.cells)-1) >= MinFill:
			last := l.cells[len(l.cells)-1]
			l.cells = l.cells[:len(l.cells)-1]
			if n.isLeaf() {
				n.cells = append([]cell{last}, n.cells...)
				par.cells[j-1].key = l.cells[len(l.cells)-1].key
			} else {
				n.cells = append([]cell{{key: par.cells[j-1].key, child: l.link}}, n.cells...)
				par.cells[j-1].key = last.key
				l.link = last.child
			}
			p.write(lpage, l.encode())
			p.write(page, n.encode())
			t.store(path, st.page, par)
			return

		case r != nil && r.used()-r.cost(0) >= MinFill:
			first := r.cells[0]
			r.cells = r.cells[1:]
			if n.isLeaf() {
				n.cells = append(n.cells, first)
				par.cells[j].key = first.key
			} else {
				n.cells = append(n.cells, cell{key: par.cells[j].key, child: n.link})
				n.link = first.child
				par.cells[j].key = first.key
			}
			p.write(rpage, r.encode())
			p.write(page, n.encode())
			t.store(path, st.page, par)
			return

		case l != nil: // merge N into its left sibling
			if n.isLeaf() {
				l.cells = append(l.cells, n.cells...)
			} else {
				l.cells = append(l.cells, cell{key: par.cells[j-1].key, child: l.link})
				l.cells = append(l.cells, n.cells...)
			}
			l.link = n.link
			par.cells = append(par.cells[:j-1], par.cells[j:]...)
			if j == np {
				par.link = lpage
			} else {
				par.cells[j-1].child = lpage
			}
			p.write(lpage, l.encode())
			p.free(page)

		default: // merge the right sibling into N
			if n.isLeaf() {
				n.cells = append(n.cells, r.cells...)
			} else {
				n.cells = append(n.cells, cell{key: par.cells[j].key, child: n.link})
				n.cells = append(n.cells, r.cells...)
			}
			n.link = r.link
			par.cells = append(par.cells[:j], par.cells[j+1:]...)
			if j+1 == np {
				par.link = page
			} else {
				par.cells[j].child = page
			}
			p.write(page, n.encode())
			p.free(rpage)
		}

		// A merge removed a cell from the parent.
		if len(path) == 0 { // parent is the root
			if len(par.cells) == 0 {
				*t.root = par.link
				p.free(st.page)
			} else {
				p.write(st.page, par.encode())
			}
			return
		}
		p.write(st.page, par.encode())
		if par.used() >= MinFill {
			return
		}
		page, n = st.page, par
	}
}

// freeAll frees every page of the tree rooted at page in post-order and
// returns the number of pages freed.
func (t *tree) freeAll(page uint32) int {
	img := t.p.read(page)
	count := 0
	if img[0] == typeInterior {
		// Collect children first: freeing rewrites pages.
		n := pageCellCount(img)
		kids := make([]uint32, 0, n+1)
		for i := 0; i < n; i++ {
			kids = append(kids, rawChild(img, i))
		}
		kids = append(kids, pageLink(img))
		for _, k := range kids {
			count += t.freeAll(k)
		}
	}
	t.p.free(page)
	return count + 1
}

// height returns the tree height: 0 when empty, 1 for a lone leaf.
func (t *tree) height() int {
	if *t.root == 0 {
		return 0
	}
	h := 1
	img := t.p.read(*t.root)
	for img[0] == typeInterior {
		h++
		if pageCellCount(img) > 0 {
			img = t.p.read(rawChild(img, 0))
		} else {
			img = t.p.read(pageLink(img))
		}
	}
	return h
}
