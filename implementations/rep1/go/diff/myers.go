package linediff

// negInf marks a diagonal whose furthest-reaching point lies outside the
// edit grid. It is far below any real coordinate and adding small numbers to
// it never makes it look reachable.
const negInf = -1 << 40

// search holds the state shared by all recursive calls: the two sequences,
// the output operations, and the forward/backward frontier arrays, which are
// allocated once and reused by every call.
type search struct {
	a, b   []int32
	ops    []Op
	vf, vb []int
	off    int // diagonal k lives at index k+off
}

func newSearch(a, b []int32) *search {
	maxD := (len(a)+len(b)+1)/2 + 1
	return &search{
		a:   a,
		b:   b,
		ops: make([]Op, 0, len(a)+len(b)),
		vf:  make([]int, 2*maxD+3),
		vb:  make([]int, 2*maxD+3),
		off: maxD + 1,
	}
}

// diff appends a minimal script for a[a0:a1] -> b[b0:b1] to s.ops.
func (s *search) diff(a0, a1, b0, b1 int) {
	a, b := s.a, s.b
	// Common prefix: emitted immediately.
	for a0 < a1 && b0 < b1 && a[a0] == b[b0] {
		s.ops = append(s.ops, Op{Keep, int32(a0)})
		a0++
		b0++
	}
	// Common suffix: emitted after the middle.
	t := 0
	for a0 < a1 && b0 < b1 && a[a1-1] == b[b1-1] {
		a1--
		b1--
		t++
	}
	switch {
	case a0 == a1:
		for j := b0; j < b1; j++ {
			s.ops = append(s.ops, Op{Insert, int32(j)})
		}
	case b0 == b1:
		for i := a0; i < a1; i++ {
			s.ops = append(s.ops, Op{Delete, int32(i)})
		}
	default:
		x0, y0, x1, y1 := s.middleSnake(a[a0:a1], b[b0:b1])
		s.diff(a0, a0+x0, b0, b0+y0)
		for i := x0; i < x1; i++ {
			s.ops = append(s.ops, Op{Keep, int32(a0 + i)})
		}
		s.diff(a0+x1, a1, b0+y1, b1)
	}
	for i := 0; i < t; i++ {
		s.ops = append(s.ops, Op{Keep, int32(a1 + i)})
	}
}

// middleSnake finds the middle snake of the edit graph of a and b, which must
// both be non-empty with no common first or last element. It returns the
// snake as the diagonal run from (x0,y0) to (x1,y1) (possibly of length
// zero). The minimal script splits into a minimal script for the rectangle
// before (x0,y0) and one for the rectangle after (x1,y1).
func (s *search) middleSnake(a, b []int32) (x0, y0, x1, y1 int) {
	n, m := len(a), len(b)
	delta := n - m
	odd := delta&1 != 0
	maxD := (n + m + 1) / 2
	vf, vb, off := s.vf, s.vb, s.off

	for d := 0; d <= maxD; d++ {
		// Forward search: furthest-reaching d-paths from (0,0).
		for k := -d; k <= d; k += 2 {
			x := startPoint(vf, off, d, k, n, m)
			if x < 0 {
				vf[off+k] = negInf
				continue
			}
			sx := x
			for x < n && x-k < m && a[x] == b[x-k] {
				x++
			}
			vf[off+k] = x
			// Odd delta: overlap with the backward frontier of round d-1.
			// The backward diagonal is delta-k and must lie in [-(d-1), d-1].
			if odd {
				if kb := delta - k; kb >= -(d-1) && kb <= d-1 && x+vb[off+kb] >= n {
					return sx, sx - k, x, x - k
				}
			}
		}
		// Backward search, in reversed coordinates: furthest-reaching
		// d-paths from (n,m) toward (0,0).
		for k := -d; k <= d; k += 2 {
			x := startPoint(vb, off, d, k, n, m)
			if x < 0 {
				vb[off+k] = negInf
				continue
			}
			sx := x
			for x < n && x-k < m && a[n-1-x] == b[m-1-(x-k)] {
				x++
			}
			vb[off+k] = x
			// Even delta: overlap with the forward frontier of round d.
			// The forward diagonal is delta-k and must lie in [-d, d].
			if !odd {
				if kf := delta - k; kf >= -d && kf <= d && x+vf[off+kf] >= n {
					return n - x, m - (x - k), n - sx, m - (sx - k)
				}
			}
		}
	}
	panic("linediff: middle snake not found")
}

// startPoint returns the x coordinate where the snake on diagonal k of round
// d begins: the furthest of the points reachable by one step from round d-1's
// frontier v, or -1 when no in-grid point is reachable. It only reads
// diagonals k-1 and k+1 of round d-1, so stale entries are never touched.
func startPoint(v []int, off, d, k, n, m int) int {
	if d == 0 {
		return 0
	}
	x := -1
	// Step right from diagonal k-1 (consumes an element of a).
	if k != -d {
		if r := v[off+k-1] + 1; r >= 1 && r <= n {
			x = r
		}
	}
	// Step down from diagonal k+1 (consumes an element of b).
	if k != d {
		if r := v[off+k+1]; r >= 0 && r-k <= m && r > x {
			x = r
		}
	}
	return x
}
