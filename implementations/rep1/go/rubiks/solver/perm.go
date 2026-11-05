package solver

// This file holds ranking functions for permutations and subsets.

// fact[n] = n!
var fact = [...]int{1, 1, 2, 6, 24, 120, 720, 5040, 40320}

// rankPerm returns the Lehmer-code rank of permutation p (0 for the
// identity). len(p) must be at most 8.
func rankPerm(p []uint8) int {
	n := len(p)
	r := 0
	for i := 0; i < n-1; i++ {
		smaller := 0
		for j := i + 1; j < n; j++ {
			if p[j] < p[i] {
				smaller++
			}
		}
		r += smaller * fact[n-1-i]
	}
	return r
}

// unrankPerm fills p (of length n <= 8) with the permutation of rank r.
func unrankPerm(r int, p []uint8) {
	n := len(p)
	var avail [8]uint8
	for i := 0; i < n; i++ {
		avail[i] = uint8(i)
	}
	for i := 0; i < n; i++ {
		f := fact[n-1-i]
		k := r / f
		r %= f
		p[i] = avail[k]
		copy(avail[k:n], avail[k+1:n])
	}
}

// subsetIndex ranks the k-element subsets of an n-element set, which are
// represented as n-bit masks with k bits set.
type subsetIndex struct {
	rank []int16  // rank[mask], or -1 if mask has the wrong popcount
	mask []uint16 // mask[rank]
}

func newSubsetIndex(n, k int) *subsetIndex {
	s := &subsetIndex{rank: make([]int16, 1<<n)}
	for m := range s.rank {
		s.rank[m] = -1
		if popcount(m) == k {
			s.rank[m] = int16(len(s.mask))
			s.mask = append(s.mask, uint16(m))
		}
	}
	return s
}

func popcount(x int) int {
	n := 0
	for ; x != 0; x &= x - 1 {
		n++
	}
	return n
}

// perm4 ranks permutations of four elements (0..23).
func rankPerm4(p [4]uint8) int { return rankPerm(p[:]) }
