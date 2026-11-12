package tessera

import "encoding/binary"

// cell is one cell of a B+tree page. Which fields are meaningful depends on
// the page type: interior cells use key and child; primary leaf cells use key,
// docLen, overflow and inline; index leaf cells use only key.
type cell struct {
	key      []byte
	child    uint32
	docLen   uint32
	overflow uint32
	inline   []byte
}

// node is the logical content of a B+tree page (SPEC §11).
type node struct {
	typ   byte
	link  uint32
	cells []cell
}

func cellSize(typ byte, c *cell) int {
	switch typ {
	case typeLeaf:
		return 12 + len(c.key) + len(c.inline)
	case typeInterior:
		return 6 + len(c.key)
	default:
		return 2 + len(c.key)
	}
}

// cost is the cell's size plus its pointer.
func (n *node) cost(i int) int { return cellSize(n.typ, &n.cells[i]) + 2 }

// used is the payload size of the page.
func (n *node) used() int {
	t := 0
	for i := range n.cells {
		t += cellSize(n.typ, &n.cells[i]) + 2
	}
	return t
}

// decodeNode parses a canonical B+tree page. Keys and inline data alias p,
// which must therefore never be modified afterwards.
func decodeNode(p []byte) *node {
	n := &node{typ: p[0]}
	count := int(binary.BigEndian.Uint16(p[2:]))
	n.link = binary.BigEndian.Uint32(p[8:])
	n.cells = make([]cell, count)
	for i := 0; i < count; i++ {
		o := int(binary.BigEndian.Uint16(p[PageHeader+2*i:]))
		c := &n.cells[i]
		switch n.typ {
		case typeLeaf:
			kl := int(binary.BigEndian.Uint16(p[o:]))
			c.docLen = binary.BigEndian.Uint32(p[o+2:])
			il := int(binary.BigEndian.Uint16(p[o+6:]))
			c.overflow = binary.BigEndian.Uint32(p[o+8:])
			c.key = p[o+12 : o+12+kl : o+12+kl]
			c.inline = p[o+12+kl : o+12+kl+il : o+12+kl+il]
		case typeInterior:
			kl := int(binary.BigEndian.Uint16(p[o:]))
			c.child = binary.BigEndian.Uint32(p[o+2:])
			c.key = p[o+6 : o+6+kl : o+6+kl]
		default:
			kl := int(binary.BigEndian.Uint16(p[o:]))
			c.key = p[o+2 : o+2+kl : o+2+kl]
		}
	}
	return n
}

// encode renders the node as a canonical page: pointer array in key order,
// cells packed contiguously up to the end of the page, zero fill between.
func (n *node) encode() []byte {
	p := make([]byte, PageSize)
	total := 0
	for i := range n.cells {
		total += cellSize(n.typ, &n.cells[i])
	}
	start := PageSize - total
	p[0] = n.typ
	binary.BigEndian.PutUint16(p[2:], uint16(len(n.cells)))
	binary.BigEndian.PutUint16(p[4:], uint16(start))
	binary.BigEndian.PutUint32(p[8:], n.link)
	o := start
	for i := range n.cells {
		c := &n.cells[i]
		binary.BigEndian.PutUint16(p[PageHeader+2*i:], uint16(o))
		switch n.typ {
		case typeLeaf:
			binary.BigEndian.PutUint16(p[o:], uint16(len(c.key)))
			binary.BigEndian.PutUint32(p[o+2:], c.docLen)
			binary.BigEndian.PutUint16(p[o+6:], uint16(len(c.inline)))
			binary.BigEndian.PutUint32(p[o+8:], c.overflow)
			copy(p[o+12:], c.key)
			copy(p[o+12+len(c.key):], c.inline)
		case typeInterior:
			binary.BigEndian.PutUint16(p[o:], uint16(len(c.key)))
			binary.BigEndian.PutUint32(p[o+2:], c.child)
			copy(p[o+6:], c.key)
		default:
			binary.BigEndian.PutUint16(p[o:], uint16(len(c.key)))
			copy(p[o+2:], c.key)
		}
		o += cellSize(n.typ, c)
	}
	return p
}
