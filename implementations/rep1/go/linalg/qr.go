package linalg

import "math"

// QRResult is a thin Householder QR factorisation A = Q R.
type QRResult struct {
	Q *Matrix // m x n, orthonormal columns
	R *Matrix // n x n, upper triangular, non-negative diagonal
}

// QR computes the thin QR factorisation of an m x n matrix with m >= n
// (ErrDimensionMismatch otherwise) using Householder reflectors. The
// factorisation is made unique by forcing a non-negative diagonal on R.
// A zero column simply yields an identity reflector, so QR also succeeds on
// rank-deficient input.
func QR(a *Matrix) (*QRResult, error) {
	m, n := a.Rows, a.Cols
	if m < n {
		return nil, ErrDimensionMismatch
	}
	r := a.Clone()
	vs := make([][]float64, n) // vs[k] has length m-k; nil = identity reflector
	w := make([]float64, n)
	for k := 0; k < n; k++ {
		nu := 0.0
		for i := k; i < m; i++ {
			x := r.Data[i*n+k]
			nu += x * x
		}
		nu = math.Sqrt(nu)
		if nu == 0 {
			for i := k + 1; i < m; i++ {
				r.Data[i*n+k] = 0
			}
			continue
		}
		alpha := -nu
		if r.Data[k*n+k] < 0 {
			alpha = nu
		}
		v := make([]float64, m-k)
		for i := range v {
			v[i] = r.Data[(k+i)*n+k]
		}
		v[0] -= alpha
		ss := 0.0
		for _, x := range v {
			ss += x * x
		}
		norm := math.Sqrt(ss)
		for i := range v {
			v[i] /= norm
		}
		vs[k] = v
		applyReflector(r.Data, n, v, k, k+1, n, w)
		r.Data[k*n+k] = alpha
		for i := k + 1; i < m; i++ {
			r.Data[i*n+k] = 0
		}
	}

	q := New(m, n)
	for j := 0; j < n; j++ {
		q.Data[j*n+j] = 1
	}
	for k := n - 1; k >= 0; k-- {
		if vs[k] != nil {
			applyReflector(q.Data, n, vs[k], k, k, n, w)
		}
	}

	rr := New(n, n)
	copy(rr.Data, r.Data[:n*n])
	for j := 0; j < n; j++ {
		if rr.Data[j*n+j] < 0 {
			row := rr.Row(j)
			for c := range row {
				row[c] = -row[c]
			}
			for i := 0; i < m; i++ {
				q.Data[i*n+j] = -q.Data[i*n+j]
			}
		}
		for c := 0; c < j; c++ {
			rr.Data[j*n+c] = 0
		}
	}
	return &QRResult{Q: q, R: rr}, nil
}

// applyReflector applies H = I - 2 v vᵀ (v supported on rows k..k+len(v)-1)
// to columns c0..c1-1 of the row-major matrix d with the given row stride.
// For each column the dot product runs over increasing row index. w is
// scratch of length >= c1.
func applyReflector(d []float64, stride int, v []float64, k, c0, c1 int, w []float64) {
	w = w[c0:c1]
	for j := range w {
		w[j] = 0
	}
	for i, vi := range v {
		row := d[(k+i)*stride+c0 : (k+i)*stride+c1]
		for j, x := range row {
			w[j] += vi * x
		}
	}
	for j := range w {
		w[j] *= 2
	}
	for i, vi := range v {
		row := d[(k+i)*stride+c0 : (k+i)*stride+c1]
		for j := range row {
			row[j] -= w[j] * vi
		}
	}
}

// LeastSquares returns the n x k matrix X minimising ‖A X - B‖F for A of
// shape m x n (m >= n) and B of shape m x k. Both shape violations are
// ErrDimensionMismatch. It factors A = Q R, forms Qᵀ B and back-substitutes;
// ErrSingular is returned when a diagonal entry of R is exactly zero.
func LeastSquares(a, b *Matrix) (*Matrix, error) {
	m, n := a.Rows, a.Cols
	if m < n || b.Rows != m {
		return nil, ErrDimensionMismatch
	}
	f, err := QR(a)
	if err != nil {
		return nil, err
	}
	for j := 0; j < n; j++ {
		if f.R.Data[j*n+j] == 0 {
			return nil, ErrSingular
		}
	}
	k := b.Cols
	y := New(n, k)
	for i := 0; i < m; i++ {
		qi, bi := f.Q.Row(i), b.Row(i)
		for j, q := range qi {
			if q == 0 {
				continue
			}
			yj := y.Row(j)
			for c, v := range bi {
				yj[c] += q * v
			}
		}
	}
	for i := n - 1; i >= 0; i-- {
		yi := y.Row(i)
		ri := f.R.Row(i)
		for j := i + 1; j < n; j++ {
			u := ri[j]
			if u == 0 {
				continue
			}
			for c, v := range y.Row(j) {
				yi[c] -= u * v
			}
		}
		d := ri[i]
		for c := range yi {
			yi[c] /= d
		}
	}
	return y, nil
}
