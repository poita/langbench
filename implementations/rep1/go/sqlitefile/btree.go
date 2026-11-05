package sqlitefile

import (
	"encoding/binary"
	"sort"
)

// reader performs B-tree reads against a pager. It owns a scratch buffer that
// holds payloads reassembled from overflow pages, so a reader must not be used
// concurrently, and a payload handed to a visitor is only valid until the next
// cell is read.
type reader struct {
	pg      *pager
	scratch []byte
	visits  int // pages entered by the current walk; bounds cyclic trees
}

// visit counts a page entered during a whole-tree walk. A valid tree enters
// each page at most once, so exceeding the page count means a cycle.
func (r *reader) visit() error {
	r.visits++
	if r.visits > r.pg.nPages {
		return ErrCorrupt
	}
	return nil
}

// cellVisitor receives a table row or index entry in key order. volatile is
// true when payload lives in the reader's scratch buffer and so must be copied
// if it is to outlive the call. Returning true stops the walk.
type cellVisitor func(rowid int64, payload []byte, volatile bool) (stop bool, err error)

// payloadAt returns the full payload of a cell. start is the page offset of the
// first payload byte and p the total payload size from the cell's varint. When
// the payload spills onto overflow pages it is reassembled in the scratch
// buffer and volatile is true.
func (r *reader) payloadAt(pg []byte, start int, p uint64, leafTable bool) (payload []byte, volatile bool, err error) {
	if p > uint64(len(r.pg.data)) {
		return nil, false, ErrCorrupt
	}
	total := int(p)
	local := r.pg.localSize(total, leafTable)
	if start+local > r.pg.usable {
		return nil, false, ErrCorrupt
	}
	if local == total {
		return pg[start : start+local : start+local], false, nil
	}
	if start+local+4 > r.pg.usable {
		return nil, false, ErrCorrupt
	}
	buf := append(r.scratch[:0], pg[start:start+local]...)
	next := binary.BigEndian.Uint32(pg[start+local:])
	remaining := total - local
	chunk := r.pg.usable - 4
	for hops := 0; remaining > 0; hops++ {
		if next == 0 || hops > r.pg.nPages {
			return nil, false, ErrCorrupt
		}
		op, err := r.pg.raw(next)
		if err != nil {
			return nil, false, err
		}
		next = binary.BigEndian.Uint32(op)
		n := remaining
		if n > chunk {
			n = chunk
		}
		buf = append(buf, op[4:4+n]...)
		remaining -= n
	}
	r.scratch = buf
	return buf, true, nil
}

// tableLeafCell decodes a table leaf cell.
func (r *reader) tableLeafCell(pg []byte, off int) (int64, []byte, bool, error) {
	p, n := getVarint(pg[off:])
	if n == 0 {
		return 0, nil, false, ErrCorrupt
	}
	rowid, m := getVarint(pg[off+n:])
	if m == 0 {
		return 0, nil, false, ErrCorrupt
	}
	payload, vol, err := r.payloadAt(pg, off+n+m, p, true)
	return int64(rowid), payload, vol, err
}

// indexCell decodes an index cell; interior cells have a 4-byte child pointer
// first. It returns the payload and, for interior cells, the child page.
func (r *reader) indexCell(pg []byte, off int, interior bool) (payload []byte, volatile bool, child uint32, err error) {
	if interior {
		if off+4 > len(pg) {
			return nil, false, 0, ErrCorrupt
		}
		child = binary.BigEndian.Uint32(pg[off:])
		off += 4
	}
	p, n := getVarint(pg[off:])
	if n == 0 {
		return nil, false, 0, ErrCorrupt
	}
	payload, volatile, err = r.payloadAt(pg, off+n, p, false)
	return
}

// tableInteriorCell decodes a table interior cell into (left child, key).
func tableInteriorCell(pg []byte, off int) (uint32, int64, error) {
	if off+5 > len(pg) {
		return 0, 0, ErrCorrupt
	}
	k, n := getVarint(pg[off+4:])
	if n == 0 {
		return 0, 0, ErrCorrupt
	}
	return binary.BigEndian.Uint32(pg[off:]), int64(k), nil
}

// walkTable visits every row of the table B-tree rooted at root in ascending
// rowid order.
func (r *reader) walkTable(root uint32, fn cellVisitor) error {
	r.visits = 0
	_, err := r.walkTablePage(root, fn, 0)
	return err
}

func (r *reader) walkTablePage(n uint32, fn cellVisitor, depth int) (bool, error) {
	if depth > maxDepth {
		return false, ErrCorrupt
	}
	if err := r.visit(); err != nil {
		return false, err
	}
	pg, h, err := r.pg.page(n)
	if err != nil {
		return false, err
	}
	switch h.kind {
	case pageLeafTable:
		for i := 0; i < h.cells; i++ {
			off, err := r.pg.cellOffset(pg, h, i)
			if err != nil {
				return false, err
			}
			rowid, payload, vol, err := r.tableLeafCell(pg, off)
			if err != nil {
				return false, err
			}
			stop, err := fn(rowid, payload, vol)
			if stop || err != nil {
				return stop, err
			}
		}
		return false, nil
	case pageInteriorTable:
		for i := 0; i < h.cells; i++ {
			off, err := r.pg.cellOffset(pg, h, i)
			if err != nil {
				return false, err
			}
			child, _, err := tableInteriorCell(pg, off)
			if err != nil {
				return false, err
			}
			stop, err := r.walkTablePage(child, fn, depth+1)
			if stop || err != nil {
				return stop, err
			}
		}
		return r.walkTablePage(h.right, fn, depth+1)
	}
	return false, ErrCorrupt
}

// countTable returns the number of rows in a table B-tree, reading only page
// headers and interior cells.
func (r *reader) countTable(n uint32, depth int) (int64, error) {
	if depth == 0 {
		r.visits = 0
	}
	if depth > maxDepth {
		return 0, ErrCorrupt
	}
	if err := r.visit(); err != nil {
		return 0, err
	}
	pg, h, err := r.pg.page(n)
	if err != nil {
		return 0, err
	}
	switch h.kind {
	case pageLeafTable:
		return int64(h.cells), nil
	case pageInteriorTable:
		var total int64
		for i := 0; i < h.cells; i++ {
			off, err := r.pg.cellOffset(pg, h, i)
			if err != nil {
				return 0, err
			}
			child, _, err := tableInteriorCell(pg, off)
			if err != nil {
				return 0, err
			}
			c, err := r.countTable(child, depth+1)
			if err != nil {
				return 0, err
			}
			total += c
		}
		c, err := r.countTable(h.right, depth+1)
		return total + c, err
	}
	return 0, ErrCorrupt
}

// seekTable finds the row with the given rowid by binary search on each level.
func (r *reader) seekTable(root uint32, rowid int64) (payload []byte, volatile, found bool, err error) {
	n := root
	for depth := 0; depth <= maxDepth; depth++ {
		pg, h, err := r.pg.page(n)
		if err != nil {
			return nil, false, false, err
		}
		switch h.kind {
		case pageInteriorTable:
			var cellErr error
			i := sort.Search(h.cells, func(i int) bool {
				off, err := r.pg.cellOffset(pg, h, i)
				if err != nil {
					cellErr = err
					return true
				}
				_, key, err := tableInteriorCell(pg, off)
				if err != nil {
					cellErr = err
					return true
				}
				return key >= rowid
			})
			if cellErr != nil {
				return nil, false, false, cellErr
			}
			if i == h.cells {
				n = h.right
				continue
			}
			off, _ := r.pg.cellOffset(pg, h, i)
			n, _, _ = tableInteriorCell(pg, off)
		case pageLeafTable:
			var cellErr error
			i := sort.Search(h.cells, func(i int) bool {
				off, err := r.pg.cellOffset(pg, h, i)
				if err != nil {
					cellErr = err
					return true
				}
				_, k := getVarint(pg[off:])
				id, m := getVarint(pg[off+k:])
				if k == 0 || m == 0 {
					cellErr = ErrCorrupt
					return true
				}
				return int64(id) >= rowid
			})
			if cellErr != nil {
				return nil, false, false, cellErr
			}
			if i == h.cells {
				return nil, false, false, nil
			}
			off, _ := r.pg.cellOffset(pg, h, i)
			id, payload, vol, err := r.tableLeafCell(pg, off)
			if err != nil {
				return nil, false, false, err
			}
			if id != rowid {
				return nil, false, false, nil
			}
			return payload, vol, true, nil
		default:
			return nil, false, false, ErrCorrupt
		}
	}
	return nil, false, false, ErrCorrupt
}

// indexEq collects the rowids of every entry in the index B-tree rooted at
// root whose first column equals key. Entries are ordered by (columns...,
// rowid), so equal keys form one contiguous run, which includes the entries
// held by interior cells. rowids are returned in tree order.
func (r *reader) indexEq(root uint32, key Value) ([]int64, error) {
	var rec record
	var out []int64
	r.visits = 0
	_, err := r.indexEqPage(root, key, &rec, &out, 0)
	return out, err
}

// indexEqPage returns stop=true once an entry greater than key was seen.
func (r *reader) indexEqPage(n uint32, key Value, rec *record, out *[]int64, depth int) (bool, error) {
	if depth > maxDepth {
		return false, ErrCorrupt
	}
	if err := r.visit(); err != nil {
		return false, err
	}
	pg, h, err := r.pg.page(n)
	if err != nil {
		return false, err
	}
	interior := h.kind == pageInteriorIndex
	if !interior && h.kind != pageLeafIndex {
		return false, ErrCorrupt
	}
	// cmp compares the first column of cell i with key.
	var cellErr error
	cmp := func(i int) (int, uint32, error) {
		off, err := r.pg.cellOffset(pg, h, i)
		if err != nil {
			return 0, 0, err
		}
		payload, _, child, err := r.indexCell(pg, off, interior)
		if err != nil {
			return 0, 0, err
		}
		if err := rec.parse(payload); err != nil {
			return 0, 0, err
		}
		return Compare(rec.value(0), key), child, nil
	}
	first := sort.Search(h.cells, func(i int) bool {
		c, _, err := cmp(i)
		if err != nil {
			cellErr = err
			return true
		}
		return c >= 0
	})
	if cellErr != nil {
		return false, cellErr
	}
	for i := first; i < h.cells; i++ {
		off, err := r.pg.cellOffset(pg, h, i)
		if err != nil {
			return false, err
		}
		if interior {
			child := binary.BigEndian.Uint32(pg[off:])
			stop, err := r.indexEqPage(child, key, rec, out, depth+1)
			if stop || err != nil {
				return stop, err
			}
		}
		c, _, err := cmp(i)
		if err != nil {
			return false, err
		}
		if c > 0 {
			return true, nil
		}
		// rec holds this cell's record only if no recursion intervened, so
		// cmp re-parsed it above.
		id, err := entryRowid(rec)
		if err != nil {
			return false, err
		}
		*out = append(*out, id)
	}
	if interior {
		return r.indexEqPage(h.right, key, rec, out, depth+1)
	}
	return false, nil
}

// entryRowid returns the rowid stored in the last column of an index record.
func entryRowid(rec *record) (int64, error) {
	n := rec.numCols()
	if n == 0 {
		return 0, ErrCorrupt
	}
	v := rec.value(n - 1)
	if v.Kind != KindInteger {
		return 0, ErrCorrupt
	}
	return v.I, nil
}
