package orderbook

import (
	"math/rand/v2"
	"slices"
	"testing"
)

func TestTreeMatchesSortedSet(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	var root *level
	set := map[uint64]bool{}
	for i := 0; i < 20000; i++ {
		p := uint64(rng.IntN(500)) + 1
		if set[p] {
			root = treeDelete(root, p)
			delete(set, p)
		} else {
			root = treeInsert(root, &level{price: p, prio: rng.Uint32()})
			set[p] = true
		}
		if i%97 != 0 {
			continue
		}
		var want []uint64
		for k := range set {
			want = append(want, k)
		}
		slices.Sort(want)

		var got []uint64
		treeWalk(root, false, func(l *level) bool { got = append(got, l.price); return true })
		if !slices.Equal(got, want) {
			t.Fatalf("step %d: ascending walk = %v, want %v", i, got, want)
		}
		got = got[:0]
		treeWalk(root, true, func(l *level) bool { got = append(got, l.price); return true })
		slices.Reverse(want)
		if !slices.Equal(got, want) {
			t.Fatalf("step %d: descending walk mismatch", i)
		}
		if len(want) > 0 {
			if treeMin(root).price != want[len(want)-1] || treeMax(root).price != want[0] {
				t.Fatalf("step %d: min/max wrong", i)
			}
		}
	}
}

func TestTreeWalkStopsEarly(t *testing.T) {
	var root *level
	for p := uint64(1); p <= 10; p++ {
		root = treeInsert(root, &level{price: p, prio: uint32(p * 2654435761)})
	}
	n := 0
	done := treeWalk(root, false, func(l *level) bool { n++; return n < 3 })
	if done || n != 3 {
		t.Fatalf("done=%v n=%d, want false and 3", done, n)
	}
}

func TestTreeEmpty(t *testing.T) {
	if treeMin(nil) != nil || treeMax(nil) != nil || treeDelete(nil, 1) != nil {
		t.Fatal("operations on an empty tree should yield nil")
	}
}
