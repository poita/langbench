package linalg

import "math"

// QRFactors is a thin Householder QR factorisation A = Q R.
type QRFactors struct {
	Q *Matrix // m x n with orthonormal columns
	R *Matrix // n x n upper triangular with a non-negative diagonal
}

// QR computes the thin Householder QR factorisation of an m x n matrix with
// m >= n (ErrDimensionMismatch otherwise). The diagonal of R is made
// non-negative by negating rows of R and the matching columns of Q.
func QR(a *Matrix) (*QRFactors, error) {
	m, n := a.Rows, a.Cols
	if m < n {
		return nil, ErrDimensionMismatch
	}
	r := a.Clone()
	rd := r.Data
	vs := make([][]float64, n) // nil entry: identity reflector
	dots := make([]float64, n)
	for k := 0; k < n; k++ {
		s := 0.0
		for i := k; i < m; i++ {
			x := rd[i*n+k]
			s += float64(x * x)
		}
		nu := math.Sqrt(s)
		if nu == 0 {
			for i := k + 1; i < m; i++ {
				rd[i*n+k] = 0
			}
			continue
		}
		alpha := -nu
		if rd[k*n+k] < 0 {
			alpha = nu
		}
		v := make([]float64, m-k)
		for i := range v {
			v[i] = rd[(k+i)*n+k]
		}
		v[0] -= alpha
		vn := 0.0
		for _, x := range v {
			vn += float64(x * x)
		}
		vn = math.Sqrt(vn)
		for i := range v {
			v[i] /= vn
		}
		vs[k] = v
		reflect(rd, n, k, k+1, v, dots)
		rd[k*n+k] = alpha
		for i := k + 1; i < m; i++ {
			rd[i*n+k] = 0
		}
	}

	q := New(m, n)
	for i := 0; i < n; i++ {
		q.Data[i*n+i] = 1
	}
	for k := n - 1; k >= 0; k-- {
		if vs[k] != nil {
			reflect(q.Data, n, k, 0, vs[k], dots)
		}
	}

	out := New(n, n)
	for j := 0; j < n; j++ {
		neg := rd[j*n+j] < 0
		for c := j; c < n; c++ {
			v := rd[j*n+c]
			if neg {
				v = -v
			}
			out.Data[j*n+c] = v
		}
		if neg {
			for i := 0; i < m; i++ {
				q.Data[i*n+j] = -q.Data[i*n+j]
			}
		}
	}
	return &QRFactors{Q: q, R: out}, nil
}

// reflect applies X[k..][c0..] -= 2 v (vᵀ X[k..][c0..]) to the row-major
// matrix d with n columns, where v has length rows-k. dots is scratch of
// length n.
func reflect(d []float64, n, k, c0 int, v, dots []float64) {
	for c := c0; c < n; c++ {
		dots[c] = 0
	}
	for i, vi := range v {
		row := d[(k+i)*n : (k+i+1)*n]
		for c := c0; c < n; c++ {
			dots[c] += float64(vi * row[c])
		}
	}
	for i, vi := range v {
		row := d[(k+i)*n : (k+i+1)*n]
		for c := c0; c < n; c++ {
			row[c] -= float64(float64(2*dots[c]) * vi)
		}
	}
}

// LeastSquares returns the n x k minimiser of ‖A X − B‖F for a full column
// rank m x n matrix A with m >= n, via QR and back substitution. It returns
// ErrDimensionMismatch for m < n or a B with the wrong row count, and
// ErrSingular if R has an exactly zero diagonal entry.
func LeastSquares(a, b *Matrix) (*Matrix, error) {
	if a.Rows < a.Cols || b.Rows != a.Rows {
		return nil, ErrDimensionMismatch
	}
	f, err := QR(a)
	if err != nil {
		return nil, err
	}
	m, n, k := a.Rows, a.Cols, b.Cols
	for i := 0; i < n; i++ {
		if f.R.Data[i*n+i] == 0 {
			return nil, ErrSingular
		}
	}
	x := New(n, k)
	rhs := make([]float64, n)
	for c := 0; c < k; c++ {
		for i := 0; i < n; i++ {
			s := 0.0
			for r := 0; r < m; r++ {
				s += float64(f.Q.Data[r*n+i] * b.Data[r*k+c])
			}
			rhs[i] = s
		}
		for i := n - 1; i >= 0; i-- {
			s := rhs[i]
			for j := i + 1; j < n; j++ {
				s -= float64(f.R.Data[i*n+j] * rhs[j])
			}
			rhs[i] = s / f.R.Data[i*n+i]
		}
		for i := 0; i < n; i++ {
			x.Data[i*k+c] = rhs[i]
		}
	}
	return x, nil
}
