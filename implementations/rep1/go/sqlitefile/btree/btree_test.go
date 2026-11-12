package btree

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"testing"

	"sqlitefile/record"
	"sqlitefile/value"
)

const testPageSize = 512

// dbBuilder assembles a tiny database image page by page.
type dbBuilder struct {
	pages [][]byte
}

func newBuilder(npages int) *dbBuilder {
	b := &dbBuilder{pages: make([][]byte, npages)}
	for i := range b.pages {
		b.pages[i] = make([]byte, testPageSize)
	}
	h := b.pages[0]
	copy(h, "SQLite format 3\x00")
	binary.BigEndian.PutUint16(h[16:], testPageSize)
	binary.BigEndian.PutUint32(h[56:], 1)
	return b
}

func (b *dbBuilder) image() []byte { return bytes.Join(b.pages, nil) }

// writeNode writes a B-tree page of the given type holding the encoded cells
// (already in key order); right is the right-most child of interior pages.
func (b *dbBuilder) writeNode(pgno int, typ byte, right uint32, cells [][]byte) {
	pg := b.pages[pgno-1]
	base := 0
	if pgno == 1 {
		base = 100
	}
	pg[base] = typ
	binary.BigEndian.PutUint16(pg[base+3:], uint16(len(cells)))
	ptr := base + 8
	if typ == TypeInteriorIndex || typ == TypeInteriorTable {
		binary.BigEndian.PutUint32(pg[base+8:], right)
		ptr = base + 12
	}
	end := len(pg)
	for _, c := range cells {
		end -= len(c)
		copy(pg[end:], c)
		binary.BigEndian.PutUint16(pg[ptr:], uint16(end))
		ptr += 2
	}
}

func tableLeafCell(rowid int64, payload []byte, overflow uint32, local int) []byte {
	c := record.PutVarint(nil, int64(len(payload)))
	c = record.PutVarint(c, rowid)
	c = append(c, payload[:local]...)
	if local < len(payload) {
		c = binary.BigEndian.AppendUint32(c, overflow)
	}
	return c
}

func tableInteriorCell(child uint32, key int64) []byte {
	return record.PutVarint(binary.BigEndian.AppendUint32(nil, child), key)
}

func rowPayload(n int64) []byte {
	return record.Encode([]value.Value{value.NewInt(n), value.NewText(fmt.Sprintf("row %d", n))})
}

func TestTableTree(t *testing.T) {
	b := newBuilder(8)
	// Leaf 3: negative rowids (nine-byte varints) and 0; leaf 4: 1..3 and an
	// overflowing payload; leaf 5: large rowids. Interior root on page 2.
	leaf := func(ids ...int64) [][]byte {
		var cells [][]byte
		for _, id := range ids {
			p := rowPayload(id)
			cells = append(cells, tableLeafCell(id, p, 0, len(p)))
		}
		return cells
	}
	b.writeNode(3, TypeLeafTable, 0, leaf(-1<<62, -5, 0))

	// Overflow payload: 1200 bytes of text. U=512: X=477, M=39, K = 39 +
	// (P-39) mod 508, so the overflow data fills exactly two pages.
	big := record.Encode([]value.Value{value.NewText(string(bytes.Repeat([]byte("xyz"), 400)))})
	local := (&Pager{usable: testPageSize}).localSize(int64(len(big)), false)
	if local >= len(big) {
		t.Fatalf("test payload does not overflow (local %d, total %d)", local, len(big))
	}
	cells4 := leaf(1, 2)
	cells4 = append(cells4, tableLeafCell(3, big, 6, local))
	b.writeNode(4, TypeLeafTable, 0, cells4)
	// Overflow chain 6 -> 7.
	rest := big[local:]
	chunk := testPageSize - 4
	binary.BigEndian.PutUint32(b.pages[5], 7)
	n := copy(b.pages[5][4:], rest)
	if n != chunk {
		t.Fatalf("expected a full first overflow page, copied %d", n)
	}
	copy(b.pages[6][4:], rest[chunk:])
	if len(rest) <= chunk || len(rest) > 2*chunk {
		t.Fatalf("overflow should need exactly two pages, remaining %d", len(rest))
	}

	b.writeNode(5, TypeLeafTable, 0, leaf(10, 1<<40))
	b.writeNode(2, TypeInteriorTable, 5, [][]byte{tableInteriorCell(3, 0), tableInteriorCell(4, 3)})
	// Page 1 is the schema table: left empty (a leaf with no cells).
	b.writeNode(1, TypeLeafTable, 0, nil)

	p, err := NewPager(b.image())
	if err != nil {
		t.Fatal(err)
	}

	wantIDs := []int64{-1 << 62, -5, 0, 1, 2, 3, 10, 1 << 40}
	var got []int64
	err = p.ScanTable(2, func(rowid int64, payload []byte) (bool, error) {
		got = append(got, rowid)
		if rowid == 3 && !bytes.Equal(payload, big) {
			t.Errorf("overflow payload mismatch: got %d bytes, want %d", len(payload), len(big))
		}
		return true, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(got) != fmt.Sprint(wantIDs) {
		t.Errorf("scan order = %v, want %v", got, wantIDs)
	}

	n64, err := p.CountTable(2)
	if err != nil || n64 != int64(len(wantIDs)) {
		t.Errorf("CountTable = %d, %v; want %d", n64, err, len(wantIDs))
	}
	if n64, err := p.CountTable(1); err != nil || n64 != 0 {
		t.Errorf("CountTable(empty page 1) = %d, %v", n64, err)
	}

	for _, id := range wantIDs {
		pl, found, err := p.SeekTable(2, id)
		if err != nil || !found {
			t.Errorf("SeekTable(%d) = found %v, err %v", id, found, err)
			continue
		}
		if id != 3 && !bytes.Equal(pl, rowPayload(id)) {
			t.Errorf("SeekTable(%d) returned the wrong payload", id)
		}
	}
	for _, id := range []int64{-1 << 63, -6, 4, 11, 1<<40 + 1} {
		if _, found, err := p.SeekTable(2, id); found || err != nil {
			t.Errorf("SeekTable(%d) = found %v, err %v; want not found", id, found, err)
		}
	}

	// Early termination.
	calls := 0
	_ = p.ScanTable(2, func(int64, []byte) (bool, error) { calls++; return calls < 4, nil })
	if calls != 4 {
		t.Errorf("scan did not stop when asked: %d calls", calls)
	}
	// Errors from the callback propagate.
	boom := errors.New("boom")
	if err := p.ScanTable(2, func(int64, []byte) (bool, error) { return true, boom }); err != boom {
		t.Errorf("callback error = %v, want boom", err)
	}
}

func indexEntry(key string, rowid int64) []byte {
	return record.Encode([]value.Value{value.NewText(key), value.NewInt(rowid)})
}

func indexLeafCell(payload []byte) []byte {
	return append(record.PutVarint(nil, int64(len(payload))), payload...)
}

func indexInteriorCell(child uint32, payload []byte) []byte {
	return append(binary.BigEndian.AppendUint32(nil, child), indexLeafCell(payload)...)
}

func TestIndexTree(t *testing.T) {
	// Interior cells b/11 and b/22 are real entries, and "b" entries fill the
	// leaves around them, so the run of equal keys spans interior cells and
	// several subtrees.
	b := newBuilder(6)
	b.writeNode(1, TypeLeafTable, 0, nil)
	b.writeNode(3, TypeLeafIndex, 0, [][]byte{
		indexLeafCell(indexEntry("a", 1)), indexLeafCell(indexEntry("b", 10)),
	})
	b.writeNode(4, TypeLeafIndex, 0, [][]byte{
		indexLeafCell(indexEntry("b", 20)), indexLeafCell(indexEntry("b", 21)),
	})
	b.writeNode(5, TypeLeafIndex, 0, [][]byte{
		indexLeafCell(indexEntry("b", 31)), indexLeafCell(indexEntry("c", 32)),
	})
	b.writeNode(2, TypeInteriorIndex, 5, [][]byte{
		indexInteriorCell(3, indexEntry("b", 11)),
		indexInteriorCell(4, indexEntry("b", 22)),
	})
	p, err := NewPager(b.image())
	if err != nil {
		t.Fatal(err)
	}
	search := func(key string) []int64 {
		var rowids []int64
		var rec record.Record
		cmp := func(e []byte) (int, error) {
			if err := rec.Reset(e); err != nil {
				return 0, err
			}
			return value.Compare(rec.Value(0), value.NewText(key)), nil
		}
		err := p.SearchIndex(2, cmp, func(e []byte) error {
			if err := rec.Reset(e); err != nil {
				return err
			}
			rowids = append(rowids, rec.Value(1).Int)
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return rowids
	}
	tests := map[string]string{
		"a":  "[1]",
		"b":  "[10 11 20 21 22 31]",
		"c":  "[32]",
		"0":  "[]",
		"bb": "[]",
		"d":  "[]",
	}
	for key, want := range tests {
		if got := fmt.Sprint(search(key)); got != want {
			t.Errorf("search(%q) = %s, want %s", key, got, want)
		}
	}
}

func TestCorruptPages(t *testing.T) {
	b := newBuilder(3)
	b.writeNode(1, TypeLeafTable, 0, nil)
	b.pages[1][0] = 0x99 // invalid page type
	p, err := NewPager(b.image())
	if err != nil {
		t.Fatal(err)
	}
	if err := p.ScanTable(2, func(int64, []byte) (bool, error) { return true, nil }); !errors.Is(err, ErrCorrupt) {
		t.Errorf("invalid page type: err = %v, want ErrCorrupt", err)
	}
	if _, err := p.CountTable(99); !errors.Is(err, ErrCorrupt) {
		t.Errorf("page out of range: err = %v, want ErrCorrupt", err)
	}
	if _, err := NewPager([]byte("not a database")); !errors.Is(err, ErrCorrupt) {
		t.Errorf("bad header: err = %v, want ErrCorrupt", err)
	}
	// A cycle must be reported, not recursed forever.
	b.writeNode(2, TypeInteriorTable, 2, nil)
	p, _ = NewPager(b.image())
	if _, err := p.CountTable(2); !errors.Is(err, ErrCorrupt) {
		t.Errorf("cycle: err = %v, want ErrCorrupt", err)
	}
}
