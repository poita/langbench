package solver

import "testing"

func TestRankUnrankPerm(t *testing.T) {
	for n := 1; n <= 8; n++ {
		p := make([]uint8, n)
		for r := 0; r < fact[n]; r++ {
			unrankPerm(r, p)
			if got := rankPerm(p); got != r {
				t.Fatalf("n=%d: rank(unrank(%d)) = %d", n, r, got)
			}
		}
	}
	id := []uint8{0, 1, 2, 3, 4, 5, 6, 7}
	if rankPerm(id) != 0 {
		t.Error("identity should have rank 0")
	}
}

func TestSubsetIndex(t *testing.T) {
	for _, tc := range []struct{ n, k, want int }{{12, 4, 495}, {8, 4, 70}, {5, 0, 1}} {
		s := newSubsetIndex(tc.n, tc.k)
		if len(s.mask) != tc.want {
			t.Errorf("C(%d,%d) = %d, want %d", tc.n, tc.k, len(s.mask), tc.want)
		}
		for r, m := range s.mask {
			if int(s.rank[m]) != r {
				t.Fatalf("rank/mask mismatch at %d", r)
			}
		}
	}
}
