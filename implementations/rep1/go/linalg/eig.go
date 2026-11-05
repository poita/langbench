package linalg

import (
	"math"
	"sort"
)

// Eigen is the result of a symmetric eigendecomposition A = V diag(w) Vᵀ.
type Eigen struct {
	Values  []float64 // ascending
	Vectors *Matrix   // n x n; column j is the unit eigenvector for Values[j]
}

const maxSweeps = 60

// EigSym computes the eigendecomposition of an exactly symmetric matrix by
// the cyclic Jacobi method (at most 60 sweeps, pairs visited in row-major
// order). Eigenvalues are returned ascending (ties keep the original order)
// and each eigenvector is sign-normalised with SignNormalize.
// It returns ErrNotSquare or ErrNotSymmetric for unsuitable input.
func EigSym(a *Matrix) (*Eigen, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	if !a.IsSymmetric() {
		return nil, ErrNotSymmetric
	}
	n := a.Rows
	M := a.Clone().Data
	vt := Identity(n).Data // row j holds column j of V
	phi := NormFro(a)
	prev := math.Inf(1)
	for sweep := 0; sweep < maxSweeps; sweep++ {
		off := offNorm(M, n)
		if off <= 1e-14*phi || off >= prev {
			break
		}
		prev = off
		for p := 0; p < n-1; p++ {
			for q := p + 1; q < n; q++ {
				if M[p*n+q] != 0 {
					jacobiRotate(M, vt, n, p, q)
				}
			}
		}
	}
	idx := make([]int, n)
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(x, y int) bool { return M[idx[x]*n+idx[x]] < M[idx[y]*n+idx[y]] })
	w := make([]float64, n)
	v := New(n, n)
	for j, o := range idx {
		w[j] = M[o*n+o]
		row := vt[o*n : (o+1)*n]
		for i, x := range row {
			v.Data[i*n+j] = x
		}
	}
	for j := 0; j < n; j++ {
		SignNormalize(v, j)
	}
	return &Eigen{Values: w, Vectors: v}, nil
}

func offNorm(M []float64, n int) float64 {
	s := 0.0
	for i := 0; i < n; i++ {
		for _, x := range M[i*n+i+1 : (i+1)*n] {
			s += x * x
		}
	}
	return math.Sqrt(2 * s)
}

// rotation returns (c, s) of the Jacobi rotation for the given θ-like
// quantity (the shared formula of the two Jacobi methods).
func rotation(theta float64) (c, s float64) {
	var t float64
	if theta >= 0 {
		t = 1 / (theta + math.Sqrt(theta*theta+1))
	} else {
		t = -1 / (-theta + math.Sqrt(theta*theta+1))
	}
	c = 1 / math.Sqrt(t*t+1)
	return c, t * c
}

// jacobiRotate applies the (p, q) rotation to the symmetric matrix M and
// accumulates it into vt (the transposed eigenvector matrix). It exploits
// the exact symmetry of M so all work is on contiguous rows; the values are
// identical to the column-pass-then-row-pass formulation.
func jacobiRotate(M, vt []float64, n, p, q int) {
	a, b, g := M[p*n+p], M[q*n+q], M[p*n+q]
	c, s := rotation((b - a) / (2 * g))
	rp, rq := M[p*n:(p+1)*n], M[q*n:(q+1)*n]
	for j := 0; j < n; j++ {
		if j == p || j == q {
			continue
		}
		x, y := rp[j], rq[j]
		nx, ny := c*x-s*y, s*x+c*y
		rp[j], rq[j] = nx, ny
		M[j*n+p], M[j*n+q] = nx, ny
	}
	P := c*a - s*g
	Pq := s*a + c*g
	Qp := c*g - s*b
	Qq := s*g + c*b
	M[p*n+p] = c*P - s*Qp
	M[q*n+q] = s*Pq + c*Qq
	M[p*n+q], M[q*n+p] = 0, 0
	vp, vq := vt[p*n:(p+1)*n], vt[q*n:(q+1)*n]
	for i, x := range vp {
		y := vq[i]
		vp[i], vq[i] = c*x-s*y, s*x+c*y
	}
}

// SignNormalize fixes the sign of column j of m: if the entry of largest
// magnitude (smallest index on ties) is negative, the whole column is
// negated. It reports whether the column was negated. An all-zero column is
// left untouched.
func SignNormalize(m *Matrix, j int) bool {
	best, bi := 0.0, -1
	for i := 0; i < m.Rows; i++ {
		if v := math.Abs(m.Data[i*m.Cols+j]); v > best {
			best, bi = v, i
		}
	}
	if bi < 0 || m.Data[bi*m.Cols+j] >= 0 {
		return false
	}
	for i := 0; i < m.Rows; i++ {
		m.Data[i*m.Cols+j] = -m.Data[i*m.Cols+j]
	}
	return true
}
