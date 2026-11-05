package linalg

import (
	"math"
	"sort"
)

// SVDResult is a thin singular value decomposition A = U diag(S) Vᵀ with
// k = min(m, n).
type SVDResult struct {
	U *Matrix   // m x k, orthonormal columns
	S []float64 // k singular values, descending, non-negative
	V *Matrix   // n x k, orthonormal columns
}

// SVD computes the thin SVD by one-sided Jacobi (at most 60 sweeps). When
// m < n the algorithm runs on Aᵀ and the roles of U and V are swapped. The
// columns of U are sign-normalised (see SignNormalize) and the matching
// columns of V negated, so A = U diag(S) Vᵀ still holds. Singular values tie
// in original column order.
func SVD(a *Matrix) *SVDResult {
	m, n := a.Rows, a.Cols
	cols := workColumns(a)
	k := len(cols)
	mp := len(cols[0])
	vcols := make([][]float64, k)
	for j := range vcols {
		vcols[j] = make([]float64, k)
		vcols[j][j] = 1
	}
	jacobiSVD(cols, vcols)

	sig := make([]float64, k)
	for j, c := range cols {
		sig[j] = colNorm(c)
	}
	idx := make([]int, k)
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(x, y int) bool { return sig[idx[x]] > sig[idx[y]] })

	left := New(mp, k) // left vectors of the working matrix
	right := New(k, k) // right vectors of the working matrix
	s := make([]float64, k)
	for j, o := range idx {
		s[j] = sig[o]
		c := cols[o]
		if sig[o] != 0 {
			for i, x := range c {
				left.Data[i*k+j] = x / sig[o]
			}
		}
		for i, x := range vcols[o] {
			right.Data[i*k+j] = x
		}
	}
	u, v := left, right
	if m < n {
		u, v = right, left
	}
	for j := 0; j < k; j++ {
		if SignNormalize(u, j) {
			for i := 0; i < v.Rows; i++ {
				v.Data[i*k+j] = -v.Data[i*k+j]
			}
		}
	}
	return &SVDResult{U: u, S: s, V: v}
}

// SingularValues returns the singular values of A in descending order. It
// runs the same sweeps as SVD without accumulating the right vectors.
func SingularValues(a *Matrix) []float64 {
	cols := workColumns(a)
	jacobiSVD(cols, nil)
	s := make([]float64, len(cols))
	for j, c := range cols {
		s[j] = colNorm(c)
	}
	sort.SliceStable(s, func(x, y int) bool { return s[x] > s[y] })
	return s
}

// Cond returns σ_max / σ_min. ErrSingular is returned when σ_min is exactly
// zero.
func Cond(a *Matrix) (float64, error) {
	s := SingularValues(a)
	if s[len(s)-1] == 0 {
		return 0, ErrSingular
	}
	return s[0] / s[len(s)-1], nil
}

// workColumns returns the columns of A (m >= n) or of Aᵀ (m < n, i.e. the
// rows of A) as separate contiguous vectors; the result always has
// min(m, n) vectors of length max(m, n).
func workColumns(a *Matrix) [][]float64 {
	m, n := a.Rows, a.Cols
	if m < n {
		cols := make([][]float64, m)
		for i := range cols {
			cols[i] = append([]float64(nil), a.Row(i)...)
		}
		return cols
	}
	buf := make([]float64, m*n)
	cols := make([][]float64, n)
	for j := range cols {
		cols[j] = buf[j*m : (j+1)*m : (j+1)*m]
	}
	for i := 0; i < m; i++ {
		for j, x := range a.Row(i) {
			cols[j][i] = x
		}
	}
	return cols
}

func colNorm(c []float64) float64 {
	s := 0.0
	for _, x := range c {
		s += x * x
	}
	return math.Sqrt(s)
}

// jacobiSVD orthogonalises the columns w in place by one-sided Jacobi
// rotations, accumulating them into v when v != nil.
func jacobiSVD(w, v [][]float64) {
	n := len(w)
	for sweep := 0; sweep < maxSweeps; sweep++ {
		rotated := false
		for p := 0; p < n-1; p++ {
			wp := w[p]
			for q := p + 1; q < n; q++ {
				wq := w[q]
				var alpha, beta, gamma float64
				for i, x := range wp {
					y := wq[i]
					alpha += x * x
					beta += y * y
					gamma += x * y
				}
				if gamma == 0 || alpha == 0 || beta == 0 ||
					math.Abs(gamma) <= 1e-14*math.Sqrt(alpha*beta) {
					continue
				}
				c, s := rotation((beta - alpha) / (2 * gamma))
				rotateCols(wp, wq, c, s)
				if v != nil {
					rotateCols(v[p], v[q], c, s)
				}
				rotated = true
			}
		}
		if !rotated {
			return
		}
	}
}

func rotateCols(xp, xq []float64, c, s float64) {
	for i, x := range xp {
		y := xq[i]
		xp[i], xq[i] = c*x-s*y, s*x+c*y
	}
}
