package engine

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"

	"example.com/kvstore/kverr"
	"example.com/kvstore/query"
	"example.com/kvstore/value"
)

func obj(fs ...value.Field) value.Value { return value.NewObject(fs) }
func str(s string) value.Value          { return value.NewString(s) }
func num(i int64) value.Value           { return value.NewInt(i) }

func mustPut(t *testing.T, db *DB, key string, v value.Value) {
	t.Helper()
	if _, err := db.Put([]byte(key), v); err != nil {
		t.Fatalf("put %q: %v", key, err)
	}
}

// checkTree verifies the structural invariants of a tree and returns the
// pages it uses and its keys in order.
func checkTree(t *testing.T, tr *tree) (pages []uint32, keys [][]byte) {
	t.Helper()
	if *tr.root == 0 {
		return nil, nil
	}
	leafDepth := -1
	var walk func(page uint32, depth int, lo, hi []byte)
	walk = func(page uint32, depth int, lo, hi []byte) {
		pages = append(pages, page)
		img := tr.p.read(page)
		n := decodeNode(img)
		if !bytes.Equal(n.encode(), img) {
			t.Fatalf("page %d is not canonical", page)
		}
		if n.used() > Capacity {
			t.Fatalf("page %d overfull: %d", page, n.used())
		}
		if len(n.cells) == 0 {
			t.Fatalf("page %d is empty", page)
		}
		for i := 1; i < len(n.cells); i++ {
			if bytes.Compare(n.cells[i-1].key, n.cells[i].key) >= 0 {
				t.Fatalf("page %d keys not increasing", page)
			}
		}
		if n.isLeaf() {
			if leafDepth < 0 {
				leafDepth = depth
			} else if leafDepth != depth {
				t.Fatalf("leaves at different depths")
			}
			for _, c := range n.cells {
				if (lo != nil && bytes.Compare(c.key, lo) <= 0) || (hi != nil && bytes.Compare(c.key, hi) > 0) {
					t.Fatalf("key %q outside separator bounds in page %d", c.key, page)
				}
				keys = append(keys, c.key)
			}
			return
		}
		prev := lo
		for _, c := range n.cells {
			walk(c.child, depth+1, prev, c.key)
			prev = c.key
		}
		walk(n.link, depth+1, prev, hi)
	}
	walk(*tr.root, 0, nil, nil)
	return pages, keys
}

// checkPages verifies that every page is either reachable, an overflow page of
// a document, an index page, or on the free list.
func checkPages(t *testing.T, db *DB) {
	t.Helper()
	seen := map[uint32]string{1: "header"}
	claim := func(p uint32, what string) {
		if prev, dup := seen[p]; dup {
			t.Fatalf("page %d used twice: %s and %s", p, prev, what)
		}
		seen[p] = what
	}
	pages, _ := checkTree(t, db.primary())
	for _, p := range pages {
		claim(p, "primary")
	}
	for c := db.primary().seek(nil); c.valid(); c.next() {
		_, ov, _ := rawLeafCell(c.img, c.cellIdx())
		for ; ov != 0; ov = binary.BigEndian.Uint32(db.read(ov)[4:]) {
			claim(ov, "overflow")
		}
	}
	for s := range db.hdr.Dir {
		if db.hdr.Dir[s].Live {
			ps, keys := checkTree(t, db.indexTree(s))
			for _, p := range ps {
				claim(p, "index")
			}
			if uint32(len(keys)) != db.hdr.Dir[s].Entries {
				t.Fatalf("index %d: %d entries, header says %d", s, len(keys), db.hdr.Dir[s].Entries)
			}
		}
	}
	n := uint32(0)
	for p := db.hdr.FreeHead; p != 0; p = binary.BigEndian.Uint32(db.read(p)[4:]) {
		claim(p, "free")
		n++
	}
	if n != db.hdr.FreeCount {
		t.Fatalf("free list has %d pages, header says %d", n, db.hdr.FreeCount)
	}
	if uint32(len(seen)) != db.hdr.PageCount {
		t.Fatalf("%d pages accounted for, page_count %d", len(seen), db.hdr.PageCount)
	}
}

func TestFreshDatabase(t *testing.T) {
	db := Open(nil, nil)
	m, w := db.Images()
	if len(m) != PageSize || !bytes.Equal(m[:16], []byte("TESSERA1\x00\x01\x04\x00\x00\x00\x00\x01")) {
		t.Fatalf("fresh header %x", m[:16])
	}
	for _, b := range m[16:] {
		if b != 0 {
			t.Fatal("fresh header not zero-filled")
		}
	}
	const hdr = "5445535357414c31000104000000000000000000000000000000000051e72153"
	if hex.EncodeToString(w) != hdr {
		t.Fatalf("wal header %x", w)
	}
}

func TestFirstCommitRecords(t *testing.T) {
	db := Open(nil, nil)
	mustPut(t, db, "a", num(1))
	_, w := db.Images()
	if len(w) != 2152 {
		t.Fatalf("wal size %d, want 2152", len(w))
	}
	want := []string{
		"010000000000000000000001000000010000040076292e36",
		"010000000000000000000001000000020000040076 0d60f7",
		"0200000000000000000000010000000200000000a8a0aa22",
	}
	got := []string{
		hex.EncodeToString(w[32:56]),
		hex.EncodeToString(w[32+1048 : 32+1048+24]),
		hex.EncodeToString(w[32+2096 : 32+2096+24]),
	}
	for i := range want {
		if got[i] != strings.ReplaceAll(want[i], " ", "") {
			t.Errorf("record %d header %s, want %s", i, got[i], want[i])
		}
	}
}

func TestOverflowFreeThenAllocateOrder(t *testing.T) {
	db := Open(nil, nil)
	big := str(strings.Repeat("x", 1996)) // serialised: 5 + 1996 = 2001... pad below
	for len(value.Serialize(big)) != 2005 {
		big = str(strings.Repeat("x", len(big.Str)+1))
	}
	mustPut(t, db, "a", big)
	if db.hdr.PageCount != 4 {
		t.Fatalf("page_count %d, want 4", db.hdr.PageCount)
	}
	mustPut(t, db, "a", big)
	if db.hdr.PageCount != 4 || db.hdr.FreeCount != 0 {
		t.Fatalf("replace changed pages: %+v", db.hdr)
	}
	_, ov, _ := func() (a, b uint32, c []byte) {
		img, i, _ := db.primary().lookup([]byte("a"))
		return rawLeafCell(img, i)
	}()
	if ov != 3 {
		t.Fatalf("overflow chain starts at %d, want 3 (chain now runs 3 -> 2)", ov)
	}
	if next := binary.BigEndian.Uint32(db.read(3)[4:]); next != 2 {
		t.Fatalf("page 3 next = %d, want 2", next)
	}
	checkPages(t, db)
	got, err := db.Get([]byte("a"))
	if err != nil || !value.Equal(got, big) {
		t.Fatalf("get after replace: %v", err)
	}
}

func TestVectorKeys(t *testing.T) {
	tests := []struct {
		v    value.Value
		want string
	}{
		{value.NewNull(), "10"},
		{value.NewBool(false), "20"},
		{value.NewBool(true), "21"},
		{num(0), "308000000000000000"},
		{num(36), "308000000000000024"},
		{num(-1), "307fffffffffffffff"},
		{num(-9223372036854775808), "300000000000000000"},
		{num(9223372036854775807), "30ffffffffffffffff"},
		{str(""), "400000"},
		{str("ada"), "406164610000"},
		{str("a\x00b"), "4061 00ff 62 0000"},
	}
	for _, tc := range tests {
		k, ok := valueKey(nil, tc.v)
		if !ok || hex.EncodeToString(k) != strings.ReplaceAll(tc.want, " ", "") {
			t.Errorf("vkey(%s) = %x, want %s", value.Render(tc.v), k, tc.want)
		}
		full := append(append([]byte(nil), k...), "u1"...)
		if n := valueKeyLen(full); n != len(k) {
			t.Errorf("valueKeyLen(%s) = %d, want %d", value.Render(tc.v), n, len(k))
		}
	}
	if _, ok := valueKey(nil, value.NewList(nil)); ok {
		t.Error("lists have no vkey")
	}
}

// TestBTreeRandom drives the primary tree and one index through random
// inserts, replacements and deletes against a model.
func TestBTreeRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	db := Open(nil, nil)
	if _, err := db.CreateIndex(value.ParsePath("n")); err != nil {
		t.Fatal(err)
	}
	model := map[string]value.Value{}
	randKey := func() string {
		n := 1 + rng.Intn(3)
		if rng.Intn(6) == 0 {
			n = 100 + rng.Intn(11)
		}
		b := make([]byte, n)
		for i := range b {
			b[i] = byte('a' + rng.Intn(6))
		}
		return string(b)
	}
	for step := 0; step < 4000; step++ {
		k := randKey()
		switch op := rng.Intn(10); {
		case op < 6:
			var v value.Value
			switch rng.Intn(4) {
			case 0:
				v = obj(value.Field{Name: "n", Value: num(int64(rng.Intn(50)))})
			case 1:
				v = obj(value.Field{Name: "n", Value: str(fmt.Sprint(rng.Intn(50)))}, value.Field{Name: "pad", Value: str(strings.Repeat("p", rng.Intn(400)))})
			case 2:
				v = str(strings.Repeat("z", rng.Intn(3000)))
			default:
				v = num(int64(rng.Intn(9)))
			}
			mustPut(t, db, k, v)
			model[k] = v
		default:
			err := db.Delete([]byte(k))
			if _, ok := model[k]; ok != (err == nil) {
				t.Fatalf("delete %q: model has=%v err=%v", k, ok, err)
			}
			delete(model, k)
		}
		if step%250 == 0 {
			checkPages(t, db)
		}
	}
	checkPages(t, db)
	var want []string
	for k := range model {
		want = append(want, k)
	}
	sort.Strings(want)
	got := db.Scan(ScanOptions{Limit: -1})
	if len(got) != len(want) || uint32(len(want)) != db.hdr.PrimaryCount {
		t.Fatalf("scan returned %d entries, model has %d (count %d)", len(got), len(want), db.hdr.PrimaryCount)
	}
	for i, e := range got {
		if string(e.Key) != want[i] || !value.Equal(e.Doc, model[want[i]]) {
			t.Fatalf("entry %d mismatch: %q", i, e.Key)
		}
	}
	rev := db.Scan(ScanOptions{Limit: 3, Reverse: true, KeysOnly: true})
	if len(rev) != 3 || string(rev[0].Key) != want[len(want)-1] || string(rev[2].Key) != want[len(want)-3] {
		t.Fatalf("reverse scan wrong")
	}
	// Delete everything: the tree must shrink to nothing and every page be free.
	for _, k := range want {
		if err := db.Delete([]byte(k)); err != nil {
			t.Fatal(err)
		}
	}
	checkPages(t, db)
	if db.hdr.PrimaryRoot != 0 || db.hdr.PrimaryCount != 0 || db.hdr.Dir[0].Entries != 0 {
		t.Fatalf("not empty after deleting everything: %+v", db.hdr)
	}
	if db.hdr.Dir[0].Root != 0 {
		t.Fatalf("index tree not empty")
	}
	if db.hdr.FreeCount+1 != db.hdr.PageCount {
		t.Fatalf("%d free of %d pages: pages leaked", db.hdr.FreeCount, db.hdr.PageCount)
	}
}

func TestFindPlansAndIndexMaintenance(t *testing.T) {
	db := Open(nil, nil)
	for i := 0; i < 60; i++ {
		mustPut(t, db, fmt.Sprintf("u%02d", i), obj(
			value.Field{Name: "age", Value: num(int64(20 + i%10))},
			value.Field{Name: "tag", Value: str(string(rune('a' + i%3)))},
		))
	}
	mustPut(t, db, "odd", obj(value.Field{Name: "age", Value: value.NewList(nil)}))
	mustPut(t, db, "none", num(1))

	pred := query.And{
		L: query.Cmp{Path: value.ParsePath("age"), Op: query.Ge, Val: num(25)},
		R: query.Cmp{Path: value.ParsePath("tag"), Op: query.Eq, Val: str("a")},
	}
	scanRes, plan := db.Find(pred, -1)
	if plan != "scan" {
		t.Fatalf("plan %q before any index", plan)
	}
	if _, err := db.CreateIndex(value.ParsePath("age")); err != nil {
		t.Fatal(err)
	}
	idxRes, plan := db.Find(pred, -1)
	if plan != "index age" {
		t.Fatalf("plan %q", plan)
	}
	if len(scanRes) != len(idxRes) || len(scanRes) == 0 {
		t.Fatalf("scan found %d, index found %d", len(scanRes), len(idxRes))
	}
	for i := range scanRes {
		if !bytes.Equal(scanRes[i].Key, idxRes[i].Key) {
			t.Fatalf("result %d differs", i)
		}
	}
	if limited, _ := db.Find(pred, 2); len(limited) != 2 || !bytes.Equal(limited[1].Key, idxRes[1].Key) {
		t.Fatal("limit")
	}
	if db.hdr.Dir[0].Entries != 60 {
		t.Fatalf("entries %d, want 60 (list and scalar docs are not indexed)", db.hdr.Dir[0].Entries)
	}
	// Maintenance: update, unset and delete keep the index exact.
	if err := db.Update([]byte("u00"), value.ParsePath("age"), str("x")); err != nil {
		t.Fatal(err)
	}
	if err := db.Unset([]byte("u01"), value.ParsePath("age")); err != nil {
		t.Fatal(err)
	}
	if err := db.Delete([]byte("u02")); err != nil {
		t.Fatal(err)
	}
	if err := db.Update([]byte("odd"), value.ParsePath("age"), num(1)); err != nil {
		t.Fatal(err)
	}
	if db.hdr.Dir[0].Entries != 59 {
		t.Fatalf("entries %d, want 59", db.hdr.Dir[0].Entries)
	}
	checkPages(t, db)
	if pages, err := db.DropIndex(value.ParsePath("age")); err != nil || pages == 0 {
		t.Fatalf("drop: %d %v", pages, err)
	}
	if _, err := db.DropIndex(value.ParsePath("age")); err != kverr.IndexMissing {
		t.Fatalf("second drop: %v", err)
	}
	checkPages(t, db)
}

func TestIndexKeyTooLong(t *testing.T) {
	db := Open(nil, nil)
	if _, err := db.CreateIndex(value.ParsePath("s")); err != nil {
		t.Fatal(err)
	}
	long := obj(value.Field{Name: "s", Value: str(strings.Repeat("x", 130))})
	if _, err := db.Put([]byte("k"), long); err != kverr.IndexKeyTooLong {
		t.Fatalf("put: %v", err)
	}
	if db.hdr.PrimaryCount != 0 || db.hdr.Commits != 1 {
		t.Fatalf("failed put changed state: %+v", db.hdr.Commits)
	}
	db2 := Open(nil, nil)
	mustPut(t, db2, "k", long)
	if _, err := db2.CreateIndex(value.ParsePath("s")); err != kverr.IndexKeyTooLong {
		t.Fatalf("create: %v", err)
	}
	if db2.hdr.IndexCount() != 0 {
		t.Fatal("failed create index left a slot")
	}
}

func TestTransactions(t *testing.T) {
	db := Open(nil, nil)
	mustPut(t, db, "a", num(1))
	before, _ := db.Images()
	before = append([]byte(nil), before...)
	hdr := db.hdr
	if err := db.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := db.Begin(); err != kverr.TxnActive {
		t.Fatalf("nested begin: %v", err)
	}
	if _, err := db.Checkpoint(); err != kverr.TxnActive {
		t.Fatalf("checkpoint in txn: %v", err)
	}
	for i := 0; i < 50; i++ {
		mustPut(t, db, fmt.Sprint("k", i), str(strings.Repeat("v", 300)))
	}
	if db.Stat().Docs != 51 {
		t.Fatal("transaction does not see its own writes")
	}
	if err := db.Rollback(); err != nil {
		t.Fatal(err)
	}
	if db.hdr != hdr {
		t.Fatalf("rollback did not restore the header")
	}
	if err := db.Rollback(); err != kverr.NoTxn {
		t.Fatalf("rollback without txn: %v", err)
	}
	if _, _, err := db.Commit(); err != kverr.NoTxn {
		t.Fatalf("commit without txn: %v", err)
	}
	checkPages(t, db)
	m, _ := db.Images()
	if !bytes.Equal(m, before) {
		t.Fatal("main file changed")
	}
}

func TestCheckpoint(t *testing.T) {
	db := Open(nil, nil)
	mustPut(t, db, "a", num(1))
	mustPut(t, db, "b", num(2))
	n, err := db.Checkpoint()
	if err != nil || n != 2 {
		t.Fatalf("checkpoint = %d, %v; want 2 pages", n, err)
	}
	m, w := db.Images()
	if len(m) != 2*PageSize || len(w) != 32 {
		t.Fatalf("sizes after checkpoint: main %d wal %d", len(m), len(w))
	}
	if n, _ := db.Checkpoint(); n != 0 {
		t.Fatalf("second checkpoint copied %d pages", n)
	}
	// A reopened database sees the data.
	db2 := Open(m, w)
	if v, err := db2.Get([]byte("b")); err != nil || v.Int != 2 {
		t.Fatalf("reopen: %v %v", v, err)
	}
}

func TestAutoCheckpoint(t *testing.T) {
	db := Open(nil, nil)
	for i := 0; len(db.wal) < WALLimit-3000; i++ {
		mustPut(t, db, fmt.Sprint("k", i), num(int64(i)))
	}
	for len(db.wal) > 32 && len(db.wal) < WALLimit+2200 {
		mustPut(t, db, "zz", num(7))
		if len(db.wal) == 32 {
			break
		}
	}
	if len(db.wal) != 32 {
		t.Fatalf("log size %d: automatic checkpoint did not run", len(db.wal))
	}
	if len(db.overlay) != 0 {
		t.Fatal("overlay not emptied")
	}
}

// TestRecoveryCuts replays a log truncated at every byte offset: the result
// must be exactly the state after the last commit record that survived.
func TestRecoveryCuts(t *testing.T) {
	db := Open(nil, nil)
	var ends []int // log size after each commit
	var counts []uint32
	for i := 0; i < 6; i++ {
		mustPut(t, db, fmt.Sprint("key", i), str(strings.Repeat("q", i*150)))
		ends = append(ends, len(db.wal))
		counts = append(counts, db.hdr.PrimaryCount)
	}
	_, w := db.Images()
	w = append([]byte(nil), w...)
	for cut := 0; cut <= len(w); cut += 7 {
		rec := Open(nil, w[:cut])
		wantEnd, wantCount := 32, uint32(0)
		for i, e := range ends {
			if e <= cut {
				wantEnd, wantCount = e, counts[i]
			}
		}
		_, rw := rec.Images()
		if len(rw) != wantEnd {
			t.Fatalf("cut %d: log length %d, want %d", cut, len(rw), wantEnd)
		}
		if rec.hdr.PrimaryCount != wantCount {
			t.Fatalf("cut %d: %d docs, want %d", cut, rec.hdr.PrimaryCount, wantCount)
		}
		if wantCount > 0 {
			checkPages(t, rec)
		}
	}
	// A damaged header discards everything.
	bad := append([]byte(nil), w...)
	bad[13] = 1
	if _, rw := Open(nil, bad).Images(); len(rw) != 32 {
		t.Fatalf("damaged header kept %d bytes", len(rw))
	}
	// Garbage appended after the last commit is trimmed.
	junk := append(append([]byte(nil), w...), 1, 2, 3, 4, 5)
	if _, rw := Open(nil, junk).Images(); !bytes.Equal(rw, w) {
		t.Fatal("trailing junk not trimmed")
	}
}
