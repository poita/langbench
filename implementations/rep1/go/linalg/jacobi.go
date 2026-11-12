package linalg

import (
	"math"
	"sort"
)

// maxSweeps bounds the number of Jacobi sweeps of both Jacobi algorithms.
const maxSweeps = 60

// jacobiRotation returns (c, s) for the rotation that annihilates a pair,
// given θ = (aqq − app) / (2 apq) (or the SVD analogue ζ).
func jacobiRotation(theta float64) (c, s float64) {
	var t float64
	if theta >= 0 {
		t = 1 / (theta + math.Sqrt(float64(theta*theta)+1))
	} else {
		t = -1 / (-theta + math.Sqrt(float64(theta*theta)+1))
	}
	c = 1 / math.Sqrt(float64(t*t)+1)
	s = float64(t * c)
	return
}

// signNormalise negates the column j of the row-major rows x cols matrix d
// if its first largest-magnitude entry is negative, and reports whether it
// did. An all-zero column is left alone.
func signNormalise(d []float64, rows, cols, j int) bool {
	best, bi := 0.0, -1
	for i := 0; i < rows; i++ {
		if v := abs(d[i*cols+j]); v > best {
			best, bi = v, i
		}
	}
	if bi < 0 || d[bi*cols+j] >= 0 {
		return false
	}
	for i := 0; i < rows; i++ {
		d[i*cols+j] = -d[i*cols+j]
	}
	return true
}

// order returns the permutation that sorts keys ascending (or descending),
// ties broken by the smaller original index.
func order(keys []float64, descending bool) []int {
	idx := make([]int, len(keys))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		if descending {
			return keys[idx[a]] > keys[idx[b]]
		}
		return keys[idx[a]] < keys[idx[b]]
	})
	return idx
}
