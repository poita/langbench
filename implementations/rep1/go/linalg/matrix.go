package linalg

import "math"

// Matrix is a dense real matrix stored in row-major order.
type Matrix struct {
	Rows, Cols int
	Data       []float64 // len Rows*Cols; element (i, j) is Data[i*Cols+j]
}

// New returns a zero matrix with the given shape.
func New(rows, cols int) *Matrix {
	return &Matrix{Rows: rows, Cols: cols, Data: make([]float64, rows*cols)}
}

// FromRows builds a matrix from a slice of equally long rows.
func FromRows(rows [][]float64) *Matrix {
	if len(rows) == 0 {
		return New(0, 0)
	}
	m := New(len(rows), len(rows[0]))
	for i, r := range rows {
		copy(m.Data[i*m.Cols:(i+1)*m.Cols], r)
	}
	return m
}

// Identity returns the n x n identity matrix.
func Identity(n int) *Matrix {
	m := New(n, n)
	for i := 0; i < n; i++ {
		m.Data[i*n+i] = 1
	}
	return m
}

// At returns element (i, j).
func (m *Matrix) At(i, j int) float64 { return m.Data[i*m.Cols+j] }

// Set assigns element (i, j).
func (m *Matrix) Set(i, j int, v float64) { m.Data[i*m.Cols+j] = v }

// Row returns row i as a slice that aliases the matrix storage.
func (m *Matrix) Row(i int) []float64 { return m.Data[i*m.Cols : (i+1)*m.Cols] }

// Clone returns a deep copy.
func (m *Matrix) Clone() *Matrix {
	c := New(m.Rows, m.Cols)
	copy(c.Data, m.Data)
	return c
}

// IsSquare reports whether the matrix has as many rows as columns.
func (m *Matrix) IsSquare() bool { return m.Rows == m.Cols }

// IsSymmetric reports whether A[i][j] == A[j][i] exactly for all i, j.
// Non-square matrices are not symmetric.
func (m *Matrix) IsSymmetric() bool {
	if !m.IsSquare() {
		return false
	}
	n := m.Rows
	for i := 0; i < n; i++ {
		for j := 0; j < i; j++ {
			if m.Data[i*n+j] != m.Data[j*n+i] {
				return false
			}
		}
	}
	return true
}

// Add returns A + B. It fails with ErrDimensionMismatch if the shapes differ.
func Add(a, b *Matrix) (*Matrix, error) {
	if a.Rows != b.Rows || a.Cols != b.Cols {
		return nil, ErrDimensionMismatch
	}
	c := New(a.Rows, a.Cols)
	for i := range c.Data {
		c.Data[i] = a.Data[i] + b.Data[i]
	}
	return c, nil
}

// Mul returns the product A B, each entry being one running sum over
// increasing k. It fails with ErrDimensionMismatch unless A.Cols == B.Rows.
func Mul(a, b *Matrix) (*Matrix, error) {
	if a.Cols != b.Rows {
		return nil, ErrDimensionMismatch
	}
	m, kk, n := a.Rows, a.Cols, b.Cols
	c := New(m, n)
	for i := 0; i < m; i++ {
		ci := c.Data[i*n : (i+1)*n]
		for k := 0; k < kk; k++ {
			aik := a.Data[i*kk+k]
			bk := b.Data[k*n : (k+1)*n]
			for j := range ci {
				ci[j] += float64(aik * bk[j])
			}
		}
	}
	return c, nil
}

// Transpose returns Aᵀ.
func Transpose(a *Matrix) *Matrix {
	t := New(a.Cols, a.Rows)
	for i := 0; i < a.Rows; i++ {
		for j := 0; j < a.Cols; j++ {
			t.Data[j*t.Cols+i] = a.Data[i*a.Cols+j]
		}
	}
	return t
}

// Norm1 returns the maximum absolute column sum, each column summed over
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

// NormInf returns the maximum absolute row sum, each row summed over
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

// NormFro returns the Frobenius norm, the squares being summed in row-major
// order.
func NormFro(a *Matrix) float64 {
	s := 0.0
	for _, v := range a.Data {
		s += float64(v * v)
	}
	return math.Sqrt(s)
}
