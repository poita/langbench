package sqlitefile

import (
	"encoding/binary"
	"math"
	"testing"
)

// This file contains a tiny SQLite file writer used only by the tests. It
// builds databases with controllable B-tree shapes (cells per page) so that
// multi-level trees, overflow chains and index runs can be exercised without
// any external tool.

func putVarint(v uint64) []byte {
	if v>>56 != 0 {
		// nine bytes: eight 7-bit groups then a full byte
		var b [9]byte
		b[8] = byte(v)
		v >>= 8
		for i := 7; i >= 0; i-- {
			b[i] = byte(v&0x7f) | 0x80
			v >>= 7
		}
		return b[:]
	}
	var tmp [9]byte
	n := 0
	for {
		tmp[n] = byte(v & 0x7f)
		n++
		v >>= 7
		if v == 0 {
			break
		}
	}
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = tmp[n-1-i]
		if i < n-1 {
			out[i] |= 0x80
		}
	}
	return out
}

func encodeRecord(vals []Value) []byte {
	var hdr, body []byte
	for _, v := range vals {
		switch v.Kind {
		case KindNull:
			hdr = append(hdr, 0)
		case KindInteger:
			switch {
			case v.I == 0:
				hdr = append(hdr, 8)
			case v.I == 1:
				hdr = append(hdr, 9)
			case v.I >= math.MinInt8 && v.I <= math.MaxInt8:
				hdr, body = append(hdr, 1), append(body, byte(v.I))
			case v.I >= math.MinInt16 && v.I <= math.MaxInt16:
				hdr, body = append(hdr, 2), binary.BigEndian.AppendUint16(body, uint16(v.I))
			case v.I >= -1<<23 && v.I < 1<<23:
				hdr, body = append(hdr, 3), append(body, byte(v.I>>16), byte(v.I>>8), byte(v.I))
			case v.I >= math.MinInt32 && v.I <= math.MaxInt32:
				hdr, body = append(hdr, 4), binary.BigEndian.AppendUint32(body, uint32(v.I))
			case v.I >= -1<<47 && v.I < 1<<47:
				hdr = append(hdr, 5)
				body = append(body, byte(v.I>>40), byte(v.I>>32), byte(v.I>>24), byte(v.I>>16), byte(v.I>>8), byte(v.I))
			default:
				hdr, body = append(hdr, 6), binary.BigEndian.AppendUint64(body, uint64(v.I))
			}
		case KindReal:
			hdr, body = append(hdr, 7), binary.BigEndian.AppendUint64(body, math.Float64bits(v.F))
		case KindText:
			hdr = append(hdr, putVarint(uint64(13+2*len(v.B)))...)
			body = append(body, v.B...)
		case KindBlob:
			hdr = append(hdr, putVarint(uint64(12+2*len(v.B)))...)
			body = append(body, v.B...)
		}
	}
	h := len(hdr) + 1 // header sizes in these tests stay below 128
	out := append([]byte{byte(h)}, hdr...)
	return append(out, body...)
}

type dbBuilder struct {
	t        *testing.T
	pageSize int
	pages    [][]byte // pages[0] is page 1
	schema   [][]Value
}

func newBuilder(t *testing.T, pageSize int) *dbBuilder {
	b := &dbBuilder{t: t, pageSize: pageSize}
	b.alloc() // page 1: schema, filled in by finish
	return b
}

func (b *dbBuilder) alloc() uint32 {
	b.pages = append(b.pages, make([]byte, b.pageSize))
	return uint32(len(b.pages))
}

func (b *dbBuilder) usable() int { return b.pageSize }

// writePage lays out cells on page n.
func (b *dbBuilder) writePage(n uint32, kind byte, cells [][]byte, right uint32) {
	pg := b.pages[n-1]
	base := 0
	if n == 1 {
		base = 100
	}
	hdrLen := 8
	if kind == pageInteriorIndex || kind == pageInteriorTable {
		hdrLen = 12
		binary.BigEndian.PutUint32(pg[base+8:], right)
	}
	pg[base] = kind
	binary.BigEndian.PutUint16(pg[base+3:], uint16(len(cells)))
	end := b.pageSize
	for i, c := range cells {
		end -= len(c)
		if end < base+hdrLen+2*len(cells) {
			b.t.Fatalf("test builder: cells do not fit on page %d", n)
		}
		copy(pg[end:], c)
		binary.BigEndian.PutUint16(pg[base+hdrLen+2*i:], uint16(end))
	}
	binary.BigEndian.PutUint16(pg[base+5:], uint16(end))
}

// payloadCell builds the tail of a cell: varint P, optional rowid, local bytes
// and overflow pointer, allocating overflow pages as needed.
func (b *dbBuilder) payloadCell(prefix []byte, rowid *int64, payload []byte, leafTable bool) []byte {
	p := &pager{usable: b.pageSize}
	local := p.localSize(len(payload), leafTable)
	cell := append([]byte{}, prefix...)
	cell = append(cell, putVarint(uint64(len(payload)))...)
	if rowid != nil {
		cell = append(cell, putVarint(uint64(*rowid))...)
	}
	cell = append(cell, payload[:local]...)
	if local == len(payload) {
		return cell
	}
	rest := payload[local:]
	first := b.alloc()
	cell = binary.BigEndian.AppendUint32(cell, first)
	cur := first
	for {
		n := len(rest)
		if n > b.pageSize-4 {
			n = b.pageSize - 4
		}
		copy(b.pages[cur-1][4:], rest[:n])
		rest = rest[n:]
		if len(rest) == 0 {
			break
		}
		next := b.alloc()
		binary.BigEndian.PutUint32(b.pages[cur-1], next)
		cur = next
	}
	return cell
}

type testRow struct {
	rowid int64
	vals  []Value
}

// table builds a table B-tree with at most leafCap rows per leaf and at most
// fan separators per interior page, and returns its root page.
func (b *dbBuilder) table(rows []testRow, leafCap, fan int) uint32 {
	var leaves []uint32
	var seps []int64
	for i := 0; i < len(rows) || i == 0; i += leafCap {
		end := min(i+leafCap, len(rows))
		var cells [][]byte
		for _, r := range rows[i:end] {
			id := r.rowid
			cells = append(cells, b.payloadCell(nil, &id, encodeRecord(r.vals), true))
		}
		n := b.alloc()
		b.writePage(n, pageLeafTable, cells, 0)
		leaves = append(leaves, n)
		if end > i {
			seps = append(seps, rows[end-1].rowid)
		}
	}
	seps = seps[:len(leaves)-1]
	return b.interior(leaves, seps, nil, fan, pageInteriorTable)
}

// index builds an index B-tree from sorted entries (each a full index record
// including the trailing rowid). Separator entries are promoted into interior
// pages, as SQLite does.
func (b *dbBuilder) index(entries [][]Value, leafCap, fan int) uint32 {
	var leaves []uint32
	var sepEntries [][]Value
	writeLeaf := func(es [][]Value) {
		var cells [][]byte
		for _, e := range es {
			cells = append(cells, b.payloadCell(nil, nil, encodeRecord(e), false))
		}
		n := b.alloc()
		b.writePage(n, pageLeafIndex, cells, 0)
		leaves = append(leaves, n)
	}
	i := 0
	for {
		end := min(i+leafCap, len(entries))
		if end+1 >= len(entries) {
			// The last leaf absorbs the remainder so that a promoted
			// separator always has a following leaf.
			writeLeaf(entries[i:])
			break
		}
		writeLeaf(entries[i:end])
		sepEntries = append(sepEntries, entries[end])
		i = end + 1
	}
	return b.interior(leaves, nil, sepEntries, fan, pageInteriorIndex)
}

// interior stacks interior levels over children. seps (table) or sepEntries
// (index) sit between consecutive children.
func (b *dbBuilder) interior(children []uint32, seps []int64, sepEntries [][]Value, fan int, kind byte) uint32 {
	for len(children) > 1 {
		var next []uint32
		var nextSeps []int64
		var nextEntries [][]Value
		i := 0
		for i < len(children) {
			n := min(fan+1, len(children)-i)
			if len(children)-i-n == 1 {
				n++
			}
			var cells [][]byte
			for j := i; j < i+n-1; j++ {
				if kind == pageInteriorTable {
					cell := binary.BigEndian.AppendUint32(nil, children[j])
					cells = append(cells, append(cell, putVarint(uint64(seps[j]))...))
				} else {
					cell := binary.BigEndian.AppendUint32(nil, children[j])
					cells = append(cells, b.payloadCell(cell, nil, encodeRecord(sepEntries[j]), false))
				}
			}
			pgNo := b.alloc()
			b.writePage(pgNo, kind, cells, children[i+n-1])
			next = append(next, pgNo)
			if i+n < len(children) {
				if kind == pageInteriorTable {
					nextSeps = append(nextSeps, seps[i+n-1])
				} else {
					nextEntries = append(nextEntries, sepEntries[i+n-1])
				}
			}
			i += n
		}
		children, seps, sepEntries = next, nextSeps, nextEntries
	}
	return children[0]
}

func (b *dbBuilder) addSchema(typ, name, tbl string, root uint32, sql string) {
	row := []Value{Text(typ), Text(name), Text(tbl), Int(int64(root)), Null()}
	if sql != "" {
		row[4] = Text(sql)
	}
	b.schema = append(b.schema, row)
}

func (b *dbBuilder) finish() []byte {
	var cells [][]byte
	for i, row := range b.schema {
		id := int64(i + 1)
		cells = append(cells, b.payloadCell(nil, &id, encodeRecord(row), true))
	}
	b.writePage(1, pageLeafTable, cells, 0)
	hdr := b.pages[0]
	copy(hdr, "SQLite format 3\x00")
	ps := b.pageSize
	if ps == 65536 {
		ps = 1
	}
	binary.BigEndian.PutUint16(hdr[16:], uint16(ps))
	hdr[18], hdr[19] = 1, 1
	hdr[21], hdr[22], hdr[23] = 64, 32, 32
	binary.BigEndian.PutUint32(hdr[28:], uint32(len(b.pages)))
	binary.BigEndian.PutUint32(hdr[44:], 4)
	binary.BigEndian.PutUint32(hdr[56:], 1)
	var out []byte
	for _, p := range b.pages {
		out = append(out, p...)
	}
	return out
}
