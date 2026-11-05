package sched

import "testing"

func TestMinHeap(t *testing.T) {
	var h minHeap
	for _, x := range []int{5, 3, 9, 1, 7, 3, 0, 8} {
		h.push(x)
	}
	prev := -1
	for h.len() > 0 {
		x := h.pop()
		if x < prev {
			t.Fatalf("out of order: %d after %d", x, prev)
		}
		prev = x
	}
}

func TestKindsAreDistinct(t *testing.T) {
	kinds := map[EventKind]bool{KindHit: true, KindRun: true, KindFail: true, KindCancel: true}
	if len(kinds) != 4 {
		t.Error("event kinds collide")
	}
}
