package engine

import (
	"bytes"
	"encoding/binary"
)

// cell is one decoded B+tree cell. Which members are used depends on the
// page type: interior cells use key and child; primary leaf cells use key,
// docLen, overflow and inline; index leaf cells use key only.
type cell struct {
	key      []byte
	child    uint32
	docLen   uint32
	overflow uint32
	inline   []byte
}

// node is a decoded B+tree page. link is the rightmost child of an interior
// page or the next leaf of a leaf page.
type node struct {
	typ   byte
	cells []cell
	link  uint32
}

// cellSize returns the encoded size of c on a page of type typ.
func cellSize(typ byte, c *cell) int {
	switch typ {
	case typeLeaf:
		return 12 + len(c.key) + len(c.inline)
	case typeInterior:
		return 6 + len(c.key)
	}
	return 2 + len(c.key)
}

func (n *node) cost(i int) int { return cellSize(n.typ, &n.cells[i]) + 2 }

// used returns the page's payload size: pointer array plus cells.
func (n *node) used() int {
	u := 0
	for i := range n.cells {
		u += n.cost(i)
	}
	return u
}

func (n *node) isLeaf() bool { return n.typ != typeInterior }

// keyOffset is the offset of the key within a cell of the given page type.
func keyOffset(typ byte) int {
	switch typ {
	case typeLeaf:
		return 12
	case typeInterior:
		return 6
	}
	return 2
}

// Raw page accessors, used by read-only operations that avoid decoding.

func pageCellCount(img []byte) int { return int(binary.BigEndian.Uint16(img[2:])) }
func pageLink(img []byte) uint32   { return binary.BigEndian.Uint32(img[8:]) }
func cellOffset(img []byte, i int) int {
	return int(binary.BigEndian.Uint16(img[16+2*i:]))
}

// rawKey returns the key of cell i, a view into img.
func rawKey(img []byte, i int) []byte {
	off := cellOffset(img, i)
	klen := int(binary.BigEndian.Uint16(img[off:]))
	ko := off + keyOffset(img[0])
	return img[ko : ko+klen]
}

// rawChild returns the child pointer of interior cell i.
func rawChild(img []byte, i int) uint32 {
	return binary.BigEndian.Uint32(img[cellOffset(img, i)+2:])
}

// rawLeafCell returns the members of primary leaf cell i; inline is a view.
func rawLeafCell(img []byte, i int) (docLen, overflow uint32, inline []byte) {
	off := cellOffset(img, i)
	klen := int(binary.BigEndian.Uint16(img[off:]))
	docLen = binary.BigEndian.Uint32(img[off+2:])
	ilen := int(binary.BigEndian.Uint16(img[off+6:]))
	overflow = binary.BigEndian.Uint32(img[off+8:])
	start := off + 12 + klen
	return docLen, overflow, img[start : start+ilen]
}

// lowerBound returns the smallest cell index i whose key is >= key (the cell
// count when there is none). It serves both leaf lookup and the interior
// descent rule "smallest i with key <= k[i]".
func lowerBound(img []byte, key []byte) int {
	lo, hi := 0, pageCellCount(img)
	for lo < hi {
		mid := (lo + hi) / 2
		if bytes.Compare(rawKey(img, mid), key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// decodeNode decodes a B+tree page. Keys and inline data are views into img,
// which must therefore not be modified afterwards (pages never are).
func decodeNode(img []byte) *node {
	n := &node{typ: img[0], link: pageLink(img)}
	cnt := pageCellCount(img)
	n.cells = make([]cell, cnt)
	for i := 0; i < cnt; i++ {
		off := cellOffset(img, i)
		klen := int(binary.BigEndian.Uint16(img[off:]))
		c := &n.cells[i]
		switch n.typ {
		case typeLeaf:
			c.docLen = binary.BigEndian.Uint32(img[off+2:])
			ilen := int(binary.BigEndian.Uint16(img[off+6:]))
			c.overflow = binary.BigEndian.Uint32(img[off+8:])
			c.key = img[off+12 : off+12+klen]
			c.inline = img[off+12+klen : off+12+klen+ilen]
		case typeInterior:
			c.child = binary.BigEndian.Uint32(img[off+2:])
			c.key = img[off+6 : off+6+klen]
		default:
			c.key = img[off+2 : off+2+klen]
		}
	}
	return n
}

// encode returns the canonical 1024-byte image of the node.
func (n *node) encode() []byte {
	img := make([]byte, PageSize)
	be := binary.BigEndian
	total := 0
	for i := range n.cells {
		total += cellSize(n.typ, &n.cells[i])
	}
	start := PageSize - total
	img[0] = n.typ
	be.PutUint16(img[2:], uint16(len(n.cells)))
	be.PutUint16(img[4:], uint16(start))
	be.PutUint32(img[8:], n.link)
	off := start
	for i := range n.cells {
		c := &n.cells[i]
		be.PutUint16(img[16+2*i:], uint16(off))
		switch n.typ {
		case typeLeaf:
			be.PutUint16(img[off:], uint16(len(c.key)))
			be.PutUint32(img[off+2:], c.docLen)
			be.PutUint16(img[off+6:], uint16(len(c.inline)))
			be.PutUint32(img[off+8:], c.overflow)
			copy(img[off+12:], c.key)
			copy(img[off+12+len(c.key):], c.inline)
		case typeInterior:
			be.PutUint16(img[off:], uint16(len(c.key)))
			be.PutUint32(img[off+2:], c.child)
			copy(img[off+6:], c.key)
		default:
			be.PutUint16(img[off:], uint16(len(c.key)))
			copy(img[off+2:], c.key)
		}
		off += cellSize(n.typ, c)
	}
	return img
}

// splitPoint returns the smallest m in 1..n-1 with 2*P[m] >= T, where P is the
// prefix sum of cell costs and T the total.
func (n *node) splitPoint() int {
	total := n.used()
	sum := 0
	for m := 1; m < len(n.cells); m++ {
		sum += n.cost(m - 1)
		if 2*sum >= total {
			return m
		}
	}
	return len(n.cells) - 1
}
