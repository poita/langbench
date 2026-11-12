package linalg

import "math"

// Cholesky returns the lower triangular L with A = L Lᵀ for a symmetric
// positive definite A, computed column by column. It returns ErrNotSquare,
// ErrNotSymmetric (exact comparison) or ErrNotPositiveDefinite (a pivot
// s <= 0) as appropriate.
func Cholesky(a *Matrix) (*Matrix, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	if !a.IsSymmetric() {
		return nil, ErrNotSymmetric
	}
	n := a.Rows
	l := New(n, n)
	ld := l.Data
	for j := 0; j < n; j++ {
		rj := ld[j*n : j*n+j]
		s := a.Data[j*n+j]
		for _, v := range rj {
			s -= float64(v * v)
		}
		if s <= 0 {
			return nil, ErrNotPositiveDefinite
		}
		d := math.Sqrt(s)
		ld[j*n+j] = d
		for i := j + 1; i < n; i++ {
			ri := ld[i*n : i*n+j]
			t := a.Data[i*n+j]
			for k, v := range ri {
				t -= float64(v * rj[k])
			}
			ld[i*n+j] = t / d
		}
	}
	return l, nil
}
