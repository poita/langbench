// Package myers implements Myers' O(ND) difference algorithm in its
// linear-space "middle snake" form (E. Myers, "An O(ND) Difference Algorithm
// and Its Variations", Algorithmica 1986, section 4b).
//
// It works on sequences of integer symbols, so comparing two elements is O(1).
// The result is always a minimal edit script: there are no cost cutoffs and no
// heuristics.
package myers

// Compare computes a shortest edit script turning a into b.
//
// It returns two marker slices: deleted[i] reports that a[i] is not part of the
// longest common subsequence found, and inserted[j] that b[j] is not. The
// number of true entries in both slices together is N + M - 2*LCS(a, b), the
// minimum possible.
//
// Time is O((N+M)·D) where D is that minimum; space is O(N+M) beyond the
// result; recursion depth is O(log D).
func Compare(a, b []int32) (deleted, inserted []bool) {
	deleted = make([]bool, len(a))
	inserted = make([]bool, len(b))
	c := &comparer{a: a, b: b, deleted: deleted, inserted: inserted}
	// Size the frontier buffers for the worst case once; every recursive call
	// reuses a prefix of them (the calls run strictly one after another).
	// After trimming, the top-level search never needs more than
	// ceil((N+M)/2)+1 rounds.
	n, m := trimmedLen(a, b)
	half := (n+m+1)/2 + 1
	c.vf = make([]int, 2*half+2)
	c.vb = make([]int, 2*half+2)
	c.solve(0, len(a), 0, len(b))
	return deleted, inserted
}

// trimmedLen returns the lengths of a and b after removing their common prefix
// and suffix.
func trimmedLen(a, b []int32) (int, int) {
	lo := 0
	for lo < len(a) && lo < len(b) && a[lo] == b[lo] {
		lo++
	}
	ea, eb := len(a), len(b)
	for ea > lo && eb > lo && a[ea-1] == b[eb-1] {
		ea--
		eb--
	}
	return ea - lo, eb - lo
}

type comparer struct {
	a, b     []int32
	deleted  []bool
	inserted []bool
	vf, vb   []int // furthest-reaching x per diagonal, forward and reverse
}

// solve marks the differences between a[alo:ahi] and b[blo:bhi].
func (c *comparer) solve(alo, ahi, blo, bhi int) {
	a, b := c.a, c.b
	// Common prefix and suffix.
	for alo < ahi && blo < bhi && a[alo] == b[blo] {
		alo++
		blo++
	}
	for alo < ahi && blo < bhi && a[ahi-1] == b[bhi-1] {
		ahi--
		bhi--
	}
	if alo == ahi {
		for j := blo; j < bhi; j++ {
			c.inserted[j] = true
		}
		return
	}
	if blo == bhi {
		for i := alo; i < ahi; i++ {
			c.deleted[i] = true
		}
		return
	}
	x, y := c.split(alo, ahi, blo, bhi)
	c.solve(alo, x, blo, y)
	c.solve(x, ahi, y, bhi)
}

// split finds a point (x, y) with alo <= x <= ahi and blo <= y <= bhi that lies
// on a shortest edit path from (alo, blo) to (ahi, bhi), strictly inside the
// rectangle's corners, by running the forward and reverse searches until they
// overlap. Both sequences must be non-empty and differ in the first and last
// element (so the edit distance is at least 2).
func (c *comparer) split(alo, ahi, blo, bhi int) (int, int) {
	a := c.a[alo:ahi]
	b := c.b[blo:bhi]
	n, m := len(a), len(b)
	delta := n - m
	odd := delta&1 != 0
	maxD := (n+m+1)/2 + 1
	off := maxD + 1
	vf := c.vf[:2*maxD+2]
	vb := c.vb[:2*maxD+2]
	for i := range vf {
		vf[i] = -1
		vb[i] = -1
	}
	vf[off+1] = 0
	vb[off+1] = 0

	// Diagonals leaving the rectangle are skipped via these bounds.
	fStart, fEnd, bStart, bEnd := 0, 0, 0, 0
	for d := 0; d <= maxD; d++ {
		// Forward search: diagonal k = x - y.
		for k := -d + fStart; k <= d-fEnd; k += 2 {
			var x int
			if k == -d || (k != d && vf[off+k-1] < vf[off+k+1]) {
				x = vf[off+k+1]
			} else {
				x = vf[off+k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			vf[off+k] = x
			if x > n {
				fEnd += 2
			} else if y > m {
				fStart += 2
			} else if odd {
				// Reverse diagonal delta-k, computed in round d-1.
				if rk := off + delta - k; rk >= 0 && rk < len(vb) && vb[rk] != -1 {
					if x >= n-vb[rk] {
						return alo + x, blo + y
					}
				}
			}
		}
		// Reverse search, on the reversed sequences: diagonal k = x' - y'.
		for k := -d + bStart; k <= d-bEnd; k += 2 {
			var x int
			if k == -d || (k != d && vb[off+k-1] < vb[off+k+1]) {
				x = vb[off+k+1]
			} else {
				x = vb[off+k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[n-1-x] == b[m-1-y] {
				x++
				y++
			}
			vb[off+k] = x
			if x > n {
				bEnd += 2
			} else if y > m {
				bStart += 2
			} else if !odd {
				// Forward diagonal delta-k, computed in round d.
				if fk := off + delta - k; fk >= 0 && fk < len(vf) && vf[fk] != -1 {
					if vf[fk] >= n-x {
						return alo + n - x, blo + m - y
					}
				}
			}
		}
	}
	panic("myers: no overlap found") // unreachable: an edit path always exists
}
