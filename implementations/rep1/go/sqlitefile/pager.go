package sqlitefile

import (
	"encoding/binary"
	"os"
)

const (
	pageInteriorIndex = 0x02
	pageInteriorTable = 0x05
	pageLeafIndex     = 0x0a
	pageLeafTable     = 0x0d

	maxDepth = 64
)

// pageHeader is the decoded B-tree page header.
type pageHeader struct {
	kind  byte
	cells int    // number of cells
	right uint32 // right-most child (interior pages only)
	ptrs  int    // offset of the cell pointer array within the page
}

func (h pageHeader) interior() bool {
	return h.kind == pageInteriorIndex || h.kind == pageInteriorTable
}

// pager gives access to the pages of an in-memory database image. Pages are
// never copied: a page is a sub-slice of the image.
type pager struct {
	data     []byte
	pageSize int
	usable   int
	nPages   int
}

func newPager(data []byte) (*pager, error) {
	if len(data) < 100 || string(data[:16]) != "SQLite format 3\x00" {
		return nil, ErrNotDatabase
	}
	ps := int(binary.BigEndian.Uint16(data[16:]))
	if ps == 1 {
		ps = 65536
	}
	if ps < 512 || ps&(ps-1) != 0 {
		return nil, ErrNotDatabase
	}
	reserved := int(data[20])
	p := &pager{data: data, pageSize: ps, usable: ps - reserved, nPages: len(data) / ps}
	if p.usable < 480 {
		return nil, ErrNotDatabase
	}
	if n := int(binary.BigEndian.Uint32(data[28:])); n > 0 && n < p.nPages {
		p.nPages = n
	}
	if len(data) < ps {
		return nil, ErrNotDatabase
	}
	return p, nil
}

// page returns page n (1-based) and its decoded B-tree header.
func (p *pager) page(n uint32) ([]byte, pageHeader, error) {
	pg, err := p.raw(n)
	if err != nil {
		return nil, pageHeader{}, err
	}
	base := 0
	if n == 1 {
		base = 100
	}
	if base+8 > len(pg) {
		return nil, pageHeader{}, ErrCorrupt
	}
	h := pageHeader{kind: pg[base], cells: int(binary.BigEndian.Uint16(pg[base+3:]))}
	switch h.kind {
	case pageInteriorIndex, pageInteriorTable:
		if base+12 > len(pg) {
			return nil, h, ErrCorrupt
		}
		h.right = binary.BigEndian.Uint32(pg[base+8:])
		h.ptrs = base + 12
	case pageLeafIndex, pageLeafTable:
		h.ptrs = base + 8
	default:
		return nil, h, ErrCorrupt
	}
	if h.ptrs+2*h.cells > p.usable {
		return nil, h, ErrCorrupt
	}
	return pg, h, nil
}

// raw returns the bytes of page n without interpreting them.
func (p *pager) raw(n uint32) ([]byte, error) {
	if n < 1 || int(n) > p.nPages {
		return nil, ErrCorrupt
	}
	start := (int(n) - 1) * p.pageSize
	return p.data[start : start+p.pageSize : start+p.pageSize], nil
}

// cellOffset returns the page offset of cell i.
func (p *pager) cellOffset(pg []byte, h pageHeader, i int) (int, error) {
	off := int(binary.BigEndian.Uint16(pg[h.ptrs+2*i:]))
	if off >= p.usable || off < h.ptrs {
		return 0, ErrCorrupt
	}
	return off, nil
}

// localSize implements the payload-overflow rule of the file format: how many
// of a P-byte payload are stored on the B-tree page itself.
func (p *pager) localSize(payload int, leafTable bool) int {
	u := p.usable
	m := (u-12)*32/255 - 23
	var x int
	if leafTable {
		x = u - 35
	} else {
		x = (u-12)*64/255 - 23
	}
	if payload <= x {
		return payload
	}
	k := m + (payload-m)%(u-4)
	if k <= x {
		return k
	}
	return m
}

// readFile loads path into memory.
func readFile(path string) ([]byte, error) { return os.ReadFile(path) }
