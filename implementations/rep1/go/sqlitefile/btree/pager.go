// Package btree reads SQLite database files: the file header, B-tree pages,
// cell payloads (including overflow chains) and in-order traversals and
// searches of table and index B-trees. It is read-only.
package btree

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
)

// Page types as stored in the first byte of a B-tree page header.
const (
	TypeInteriorIndex = 0x02
	TypeInteriorTable = 0x05
	TypeLeafIndex     = 0x0a
	TypeLeafTable     = 0x0d
)

// ErrCorrupt is wrapped by every error caused by malformed database content.
var ErrCorrupt = errors.New("btree: corrupt database")

func corrupt(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrCorrupt, fmt.Sprintf(format, args...))
}

const maxDepth = 64

var magic = []byte("SQLite format 3\x00")

// Pager gives page-level access to a database image held in memory.
type Pager struct {
	data     []byte
	pageSize int
	usable   int // page size minus reserved bytes
	pages    int
	encoding uint32
}

// NewPager validates the database header of data and returns a Pager. The
// Pager keeps a reference to data, which must not be modified.
func NewPager(data []byte) (*Pager, error) {
	if len(data) < 100 || !bytes.HasPrefix(data, magic) {
		return nil, corrupt("not a SQLite 3 database")
	}
	ps := int(binary.BigEndian.Uint16(data[16:]))
	if ps == 1 {
		ps = 65536
	}
	if ps < 512 || ps&(ps-1) != 0 {
		return nil, corrupt("invalid page size %d", ps)
	}
	reserved := int(data[20])
	if ps-reserved < 480 {
		return nil, corrupt("invalid reserved size %d", reserved)
	}
	return &Pager{
		data:     data,
		pageSize: ps,
		usable:   ps - reserved,
		pages:    len(data) / ps,
		encoding: binary.BigEndian.Uint32(data[56:]),
	}, nil
}

// Open reads the database file at path into memory and returns a Pager.
func Open(path string) (*Pager, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return NewPager(data)
}

// PageSize returns the page size in bytes.
func (p *Pager) PageSize() int { return p.pageSize }

// UsableSize returns the page size minus the reserved bytes per page.
func (p *Pager) UsableSize() int { return p.usable }

// NumPages returns the number of whole pages in the file.
func (p *Pager) NumPages() int { return p.pages }

// Encoding returns the text encoding code from the header (1 = UTF-8).
func (p *Pager) Encoding() uint32 { return p.encoding }

// page returns the bytes of page n (1-based).
func (p *Pager) page(n uint32) ([]byte, error) {
	if n < 1 || int(n) > p.pages {
		return nil, corrupt("page %d out of range", n)
	}
	off := (int(n) - 1) * p.pageSize
	return p.data[off : off+p.pageSize], nil
}

// node is a decoded B-tree page header with cell access helpers.
type node struct {
	pg     []byte
	typ    byte
	ncell  int
	right  uint32 // right-most child, interior pages only
	cellAt int    // offset of the cell pointer array
}

func (p *Pager) node(n uint32) (*node, error) {
	pg, err := p.page(n)
	if err != nil {
		return nil, err
	}
	base := 0
	if n == 1 {
		base = 100
	}
	nd := &node{pg: pg, typ: pg[base], ncell: int(binary.BigEndian.Uint16(pg[base+3:]))}
	switch nd.typ {
	case TypeInteriorIndex, TypeInteriorTable:
		nd.right = binary.BigEndian.Uint32(pg[base+8:])
		nd.cellAt = base + 12
	case TypeLeafIndex, TypeLeafTable:
		nd.cellAt = base + 8
	default:
		return nil, corrupt("page %d has invalid type 0x%02x", n, nd.typ)
	}
	if nd.cellAt+2*nd.ncell > len(pg) {
		return nil, corrupt("page %d cell pointer array overflows the page", n)
	}
	return nd, nil
}

func (nd *node) interior() bool {
	return nd.typ == TypeInteriorIndex || nd.typ == TypeInteriorTable
}

// cell returns the offset of cell i within the page.
func (nd *node) cell(i int) (int, error) {
	off := int(binary.BigEndian.Uint16(nd.pg[nd.cellAt+2*i:]))
	if off >= len(nd.pg) || off < nd.cellAt+2*nd.ncell {
		return 0, corrupt("cell offset %d out of range", off)
	}
	return off, nil
}

// child returns the page number of child i; child ncell is the right-most.
func (nd *node) child(i int) (uint32, error) {
	if i == nd.ncell {
		return nd.right, nil
	}
	off, err := nd.cell(i)
	if err != nil {
		return 0, err
	}
	if off+4 > len(nd.pg) {
		return 0, corrupt("cell overruns page")
	}
	return binary.BigEndian.Uint32(nd.pg[off:]), nil
}
