package datalog

import "testing"

func TestRelationSet(t *testing.T) {
	r := newRelation(2)
	for i := int32(0); i < 1000; i++ {
		if !r.add([]int32{i, i % 7}) {
			t.Fatalf("tuple %d reported duplicate", i)
		}
	}
	if r.add([]int32{5, 5}) {
		t.Error("duplicate (5,5) accepted")
	}
	if r.n != 1000 {
		t.Errorf("n = %d", r.n)
	}
	if !r.contains([]int32{999, 999 % 7}) || r.contains([]int32{999, 0}) {
		t.Error("contains wrong")
	}
	if newRelation(1).contains([]int32{1}) {
		t.Error("empty relation contains tuple")
	}
}

func TestIndexIncremental(t *testing.T) {
	r := newRelation(2)
	ix := r.index(1 << 1) // column 1
	if r.index(1<<1) != ix {
		t.Fatal("index not reused")
	}
	collect := func(v int32) []int32 {
		var out []int32
		for p := ix.find([]int32{v}); p >= 0; p = ix.next[p] {
			out = append(out, p)
		}
		return out
	}
	for i := int32(0); i < 50; i++ {
		r.add([]int32{i, i % 3})
	}
	ix.sync()
	for i := int32(50); i < 100; i++ {
		r.add([]int32{i, i % 3})
	}
	if got := collect(0); len(got) != 17 {
		t.Errorf("before second sync: %d entries, want 17", len(got))
	}
	ix.sync()
	got := collect(1)
	if len(got) != 33 {
		t.Fatalf("%d entries for key 1, want 33", len(got))
	}
	for i := 1; i < len(got); i++ {
		if got[i] <= got[i-1] {
			t.Fatal("positions not ascending")
		}
	}
	if ix.find([]int32{9}) != -1 {
		t.Error("found missing key")
	}
}

func TestIndexMultiColumnManyKeys(t *testing.T) {
	r := newRelation(3)
	ix := r.index(0b101)
	for i := int32(0); i < 5000; i++ {
		r.add([]int32{i % 50, i, i % 7})
	}
	ix.sync()
	n := 0
	for p := ix.find([]int32{3, 3}); p >= 0; p = ix.next[p] {
		tu := r.tuple(int(p))
		if tu[0] != 3 || tu[2] != 3 {
			t.Fatalf("bad match %v", tu)
		}
		n++
	}
	want := 0
	for i := int32(0); i < 5000; i++ {
		if i%50 == 3 && i%7 == 3 {
			want++
		}
	}
	if n != want {
		t.Errorf("got %d want %d", n, want)
	}
}
