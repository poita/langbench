package sched

import (
	"math/rand"
	"sort"
	"testing"
)

func TestHeapOrdersLikeSort(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	var h heap
	var want []int
	for i := 0; i < 500; i++ {
		x := rng.Intn(1000)
		h.push(x)
		want = append(want, x)
		if i%7 == 0 {
			sort.Ints(want)
			if got := h.pop(); got != want[0] {
				t.Fatalf("pop = %d, want %d", got, want[0])
			}
			want = want[1:]
		}
	}
	sort.Ints(want)
	for _, w := range want {
		if got := h.pop(); got != w {
			t.Fatalf("pop = %d, want %d", got, w)
		}
	}
	if h.len() != 0 {
		t.Error("heap not empty")
	}
}
