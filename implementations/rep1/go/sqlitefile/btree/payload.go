package btree

import (
	"encoding/binary"

	"sqlitefile/record"
)

// localSize computes how many payload bytes of a cell of total size P are
// stored on the page itself. index selects the index-page threshold.
func (p *Pager) localSize(total int64, index bool) int {
	u := int64(p.usable)
	m := (u-12)*32/255 - 23
	var x int64
	if index {
		x = (u-12)*64/255 - 23
	} else {
		x = u - 35
	}
	if total <= x {
		return int(total)
	}
	k := m + (total-m)%(u-4)
	if k <= x {
		return int(k)
	}
	return int(m)
}

// payload assembles the complete payload of total bytes whose first local
// bytes start at off in page nd.pg, following the overflow chain if needed.
func (p *Pager) payload(nd *node, off int, total int64, index bool) ([]byte, error) {
	if total < 0 || total > int64(len(p.data)) {
		return nil, corrupt("implausible payload size %d", total)
	}
	local := p.localSize(total, index)
	if off+local > len(nd.pg) {
		return nil, corrupt("payload overruns page")
	}
	if int64(local) == total {
		return nd.pg[off : off+local : off+local], nil
	}
	if off+local+4 > len(nd.pg) {
		return nil, corrupt("overflow pointer overruns page")
	}
	out := make([]byte, 0, total)
	out = append(out, nd.pg[off:off+local]...)
	next := binary.BigEndian.Uint32(nd.pg[off+local:])
	chunk := p.usable - 4
	for hops := 0; int64(len(out)) < total; hops++ {
		if next == 0 || hops > p.pages {
			return nil, corrupt("overflow chain ends early")
		}
		pg, err := p.page(next)
		if err != nil {
			return nil, err
		}
		next = binary.BigEndian.Uint32(pg)
		n := int64(chunk)
		if rest := total - int64(len(out)); rest < n {
			n = rest
		}
		out = append(out, pg[4:4+n]...)
	}
	return out, nil
}

// tableLeafCell returns the rowid and full payload of table leaf cell i.
func (p *Pager) tableLeafCell(nd *node, i int) (int64, []byte, error) {
	off, err := nd.cell(i)
	if err != nil {
		return 0, nil, err
	}
	total, n := record.Varint(nd.pg[off:])
	if n == 0 {
		return 0, nil, corrupt("bad payload size varint")
	}
	off += n
	rowid, n := record.Varint(nd.pg[off:])
	if n == 0 {
		return 0, nil, corrupt("bad rowid varint")
	}
	pl, err := p.payload(nd, off+n, total, false)
	return rowid, pl, err
}

// tableInteriorKey returns the rowid key of table interior cell i.
func (nd *node) tableInteriorKey(i int) (int64, error) {
	off, err := nd.cell(i)
	if err != nil {
		return 0, err
	}
	key, n := record.Varint(nd.pg[off+4:])
	if n == 0 {
		return 0, corrupt("bad interior key varint")
	}
	return key, nil
}

// indexCell returns the full payload of index cell i (leaf or interior).
func (p *Pager) indexCell(nd *node, i int) ([]byte, error) {
	off, err := nd.cell(i)
	if err != nil {
		return nil, err
	}
	if nd.interior() {
		off += 4
	}
	if off >= len(nd.pg) {
		return nil, corrupt("cell overruns page")
	}
	total, n := record.Varint(nd.pg[off:])
	if n == 0 {
		return nil, corrupt("bad payload size varint")
	}
	return p.payload(nd, off+n, total, true)
}

// varintAt decodes a varint at off in b, tolerating a short buffer.
func varintAt(b []byte, off int) (int64, int) {
	if off >= len(b) {
		return 0, 1
	}
	v, n := record.Varint(b[off:])
	if n == 0 {
		return 0, 1
	}
	return v, n
}
