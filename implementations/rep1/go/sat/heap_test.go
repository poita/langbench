package sat

import (
	"math/rand"
	"testing"
)

func TestHeapOrder(t *testing.T) {
	const n = 200
	rng := rand.New(rand.NewSource(1))
	act := make([]float64, n)
	h := varHeap{act: &act}
	h.grow(n)
	for v := range act {
		act[v] = rng.Float64()
		h.insert(v)
	}
	for i := 0; i < 50; i++ { // bump random elements
		v := rng.Intn(n)
		act[v] += 2
		h.increased(v)
	}
	prev := 1e300
	for !h.empty() {
		v := h.removeMax()
		if act[v] > prev {
			t.Fatalf("heap returned %v after %v", act[v], prev)
		}
		prev = act[v]
		if h.contains(v) {
			t.Fatalf("variable %d still in heap", v)
		}
	}
}
