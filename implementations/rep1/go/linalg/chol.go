package linalg

import "math"

// Cholesky returns the lower triangular L with A = L Lᵀ and a strictly
// positive diagonal. A must be square (ErrNotSquare), exactly symmetric
// (ErrNotSymmetric) and positive definite (ErrNotPositiveDefinite, raised
// when a pivot s <= 0 is reached). Only the lower triangle of A is read.
func Cholesky(a *Matrix) (*Matrix, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	if !a.IsSymmetric() {
		return nil, ErrNotSymmetric
	}
	n := a.Rows
	l := New(n, n)
	for j := 0; j < n; j++ {
		lj := l.Data[j*n : j*n+j]
		s := a.Data[j*n+j]
		for _, x := range lj {
			s -= x * x
		}
		if s <= 0 {
			return nil, ErrNotPositiveDefinite
		}
		d := math.Sqrt(s)
		l.Data[j*n+j] = d
		for i := j + 1; i < n; i++ {
			li := l.Data[i*n : i*n+j]
			t := a.Data[i*n+j]
			for k, x := range li {
				t -= x * lj[k]
			}
			l.Data[i*n+j] = t / d
		}
	}
	return l, nil
}
