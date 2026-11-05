package orderbook

import (
	"math/rand"
	"testing"
)

func TestSegTreeAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for _, size := range []int{0, 1, 2, 3, 7, 8, 13, 64} {
		tr := newSegTree(size)
		sum := make([]int64, size)
		ne := make([]bool, size)
		check := func() {
			lo, hi := -1, -1
			for i := 0; i < size; i++ {
				if ne[i] {
					if lo < 0 {
						lo = i
					}
					hi = i
				}
			}
			if got := tr.lowest(); got != lo {
				t.Fatalf("size %d lowest = %d, want %d", size, got, lo)
			}
			if got := tr.highest(); got != hi {
				t.Fatalf("size %d highest = %d, want %d", size, got, hi)
			}
			for i := -1; i <= size; i++ {
				wantN, wantP := -1, -1
				for j := max(i, 0); j < size; j++ {
					if ne[j] {
						wantN = j
						break
					}
				}
				for j := min(i, size-1); j >= 0; j-- {
					if ne[j] {
						wantP = j
						break
					}
				}
				if got := tr.next(i); got != wantN {
					t.Fatalf("size %d next(%d) = %d, want %d", size, i, got, wantN)
				}
				if got := tr.prev(i); got != wantP {
					t.Fatalf("size %d prev(%d) = %d, want %d", size, i, got, wantP)
				}
			}
			for i := 0; i < size; i++ {
				var pre, suf int64
				for j := 0; j <= i; j++ {
					pre += sum[j]
				}
				for j := i; j < size; j++ {
					suf += sum[j]
				}
				if got := tr.prefixSum(i); got != pre {
					t.Fatalf("size %d prefixSum(%d) = %d, want %d", size, i, got, pre)
				}
				if got := tr.suffixSum(i); got != suf {
					t.Fatalf("size %d suffixSum(%d) = %d, want %d", size, i, got, suf)
				}
			}
		}
		check()
		for step := 0; step < 200 && size > 0; step++ {
			i := rng.Intn(size)
			if rng.Intn(3) == 0 {
				sum[i], ne[i] = 0, false
			} else {
				sum[i], ne[i] = rng.Int63n(1<<40), true // sums beyond 32 bits
			}
			tr.set(i, sum[i], ne[i])
			check()
		}
	}
}
