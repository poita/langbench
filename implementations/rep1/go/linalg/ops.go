package linalg

import "math"

// Add returns A + B. The shapes must match (ErrDimensionMismatch otherwise).
func Add(a, b *Matrix) (*Matrix, error) {
	if a.Rows != b.Rows || a.Cols != b.Cols {
		return nil, ErrDimensionMismatch
	}
	c := New(a.Rows, a.Cols)
	for i, v := range a.Data {
		c.Data[i] = v + b.Data[i]
	}
	return c, nil
}

// Mul returns the product A B, where A is m x k and B is k x n
// (ErrDimensionMismatch otherwise). It uses row-axpy order, so each entry is
// a single running sum over increasing k, while the inner loop walks
// contiguous rows of B and C.
func Mul(a, b *Matrix) (*Matrix, error) {
	if a.Cols != b.Rows {
		return nil, ErrDimensionMismatch
	}
	c := New(a.Rows, b.Cols)
	for i := 0; i < a.Rows; i++ {
		ci := c.Row(i)
		for k, aik := range a.Row(i) {
			if aik == 0 {
				continue
			}
			bk := b.Row(k)
			for j, v := range bk {
				ci[j] += aik * v
			}
		}
	}
	return c, nil
}

// Transpose returns the transpose of A.
func Transpose(a *Matrix) *Matrix {
	t := New(a.Cols, a.Rows)
	for i := 0; i < a.Rows; i++ {
		for j, v := range a.Row(i) {
			t.Data[j*a.Rows+i] = v
		}
	}
	return t
}

// Norm1 returns the maximum absolute column sum. Each column is summed over
// increasing row index.
func Norm1(a *Matrix) float64 {
	sums := make([]float64, a.Cols)
	for i := 0; i < a.Rows; i++ {
		for j, v := range a.Row(i) {
			sums[j] += math.Abs(v)
		}
	}
	best := 0.0
	for _, s := range sums {
		if s > best {
			best = s
		}
	}
	return best
}

// NormInf returns the maximum absolute row sum. Each row is summed over
// increasing column index.
func NormInf(a *Matrix) float64 {
	best := 0.0
	for i := 0; i < a.Rows; i++ {
		s := 0.0
		for _, v := range a.Row(i) {
			s += math.Abs(v)
		}
		if s > best {
			best = s
		}
	}
	return best
}

// NormFro returns the Frobenius norm, the square root of the sum of squares
// accumulated row by row (increasing column within a row).
func NormFro(a *Matrix) float64 {
	s := 0.0
	for _, v := range a.Data {
		s += v * v
	}
	return math.Sqrt(s)
}
