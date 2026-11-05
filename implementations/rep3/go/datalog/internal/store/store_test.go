package store

import (
	"math/rand"
	"testing"
)

func TestInsertContainsDedup(t *testing.T) {
	r := NewRelation(2)
	if !r.Insert([]int32{1, 2}) {
		t.Fatal("first insert should be new")
	}
	if r.Insert([]int32{1, 2}) {
		t.Fatal("duplicate insert should report false")
	}
	if !r.Insert([]int32{2, 1}) {
		t.Fatal("(2,1) is distinct from (1,2)")
	}
	if r.Len() != 2 {
		t.Fatalf("Len = %d, want 2", r.Len())
	}
	if !r.Contains([]int32{2, 1}) || r.Contains([]int32{3, 3}) {
		t.Fatal("Contains gave a wrong answer")
	}
	if got := r.Tuple(1); got[0] != 2 || got[1] != 1 {
		t.Fatalf("Tuple(1) = %v", got)
	}
}

func TestInsertCopiesTuple(t *testing.T) {
	r := NewRelation(1)
	buf := []int32{7}
	r.Insert(buf)
	buf[0] = 8
	if r.Tuple(0)[0] != 7 {
		t.Fatal("relation aliases the caller's slice")
	}
}

func TestGrowth(t *testing.T) {
	r := NewRelation(2)
	const n = 5000
	for i := int32(0); i < n; i++ {
		r.Insert([]int32{i, i * 3})
	}
	for i := int32(0); i < n; i++ {
		if !r.Contains([]int32{i, i * 3}) {
			t.Fatalf("lost tuple %d", i)
		}
		if r.Contains([]int32{i, i*3 + 1}) {
			t.Fatalf("phantom tuple %d", i)
		}
	}
	if r.Len() != n {
		t.Fatalf("Len = %d", r.Len())
	}
}

func collect(ix *Index, key ...int32) []int32 {
	var out []int32
	for p := ix.First(key); p >= 0; p = ix.Next(p) {
		out = append(out, p)
	}
	return out
}

func TestIndexBucketsAscending(t *testing.T) {
	r := NewRelation(2)
	r.Insert([]int32{1, 10})
	r.Insert([]int32{2, 20})
	r.Insert([]int32{1, 30})
	ix := r.Index([]int{0})
	ix.Update()
	got := collect(ix, 1)
	if len(got) != 2 || got[0] != 0 || got[1] != 2 {
		t.Fatalf("bucket(1) = %v, want [0 2]", got)
	}
	if got := collect(ix, 9); len(got) != 0 {
		t.Fatalf("bucket(9) = %v, want empty", got)
	}
}

func TestIndexIncrementalUpdate(t *testing.T) {
	r := NewRelation(2)
	r.Insert([]int32{1, 1})
	ix := r.Index([]int{0})
	ix.Update()
	r.Insert([]int32{1, 2})
	r.Insert([]int32{5, 2})
	if got := collect(ix, 1); len(got) != 1 {
		t.Fatalf("index must not see unindexed tuples, got %v", got)
	}
	ix.Update()
	if got := collect(ix, 1); len(got) != 2 || got[1] != 1 {
		t.Fatalf("after Update bucket(1) = %v", got)
	}
	if got := collect(ix, 5); len(got) != 1 || got[0] != 2 {
		t.Fatalf("after Update bucket(5) = %v", got)
	}
}

func TestIndexIsShared(t *testing.T) {
	r := NewRelation(3)
	if r.Index([]int{0, 2}) != r.Index([]int{0, 2}) {
		t.Fatal("same columns should give the same index")
	}
	if r.Index([]int{0, 2}) == r.Index([]int{0, 1}) {
		t.Fatal("different columns should give different indexes")
	}
}

func TestIndexMultiColumnRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	r := NewRelation(3)
	ix := r.Index([]int{0, 2})
	for i := 0; i < 3000; i++ {
		r.Insert([]int32{int32(rng.Intn(20)), int32(rng.Intn(1000)), int32(rng.Intn(20))})
		if i%500 == 0 {
			ix.Update()
		}
	}
	ix.Update()
	for a := int32(0); a < 20; a++ {
		for c := int32(0); c < 20; c++ {
			var want []int32
			for p := 0; p < r.Len(); p++ {
				if row := r.Tuple(p); row[0] == a && row[2] == c {
					want = append(want, int32(p))
				}
			}
			got := collect(ix, a, c)
			if len(got) != len(want) {
				t.Fatalf("key (%d,%d): got %v want %v", a, c, got, want)
			}
			for i := range got {
				if got[i] != want[i] {
					t.Fatalf("key (%d,%d): got %v want %v", a, c, got, want)
				}
			}
		}
	}
}
