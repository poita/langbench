package linalg

// Matrix is a dense real matrix stored row-major in one flat slice:
// element (i, j) is Data[i*Cols+j].
type Matrix struct {
	Rows, Cols int
	Data       []float64
}

// New returns a zero rows x cols matrix.
func New(rows, cols int) *Matrix {
	return &Matrix{Rows: rows, Cols: cols, Data: make([]float64, rows*cols)}
}

// FromRows builds a matrix from a slice of equally long rows (the data is
// copied). It returns ErrDimensionMismatch if the rows are ragged.
func FromRows(rows [][]float64) (*Matrix, error) {
	if len(rows) == 0 {
		return New(0, 0), nil
	}
	c := len(rows[0])
	m := New(len(rows), c)
	for i, r := range rows {
		if len(r) != c {
			return nil, ErrDimensionMismatch
		}
		copy(m.Row(i), r)
	}
	return m, nil
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
func (m *Matrix) Row(i int) []float64 { return m.Data[i*m.Cols : (i+1)*m.Cols : (i+1)*m.Cols] }

// Clone returns a deep copy.
func (m *Matrix) Clone() *Matrix {
	c := &Matrix{Rows: m.Rows, Cols: m.Cols, Data: make([]float64, len(m.Data))}
	copy(c.Data, m.Data)
	return c
}

// IsSquare reports whether the matrix has as many rows as columns.
func (m *Matrix) IsSquare() bool { return m.Rows == m.Cols }

// IsSymmetric reports whether the matrix is square with A[i][j] == A[j][i]
// for all i, j, compared as exact doubles.
func (m *Matrix) IsSymmetric() bool {
	if !m.IsSquare() {
		return false
	}
	n := m.Rows
	for i := 0; i < n; i++ {
		for j := i + 1; j < n; j++ {
			if m.Data[i*n+j] != m.Data[j*n+i] {
				return false
			}
		}
	}
	return true
}

// ColVector returns an n x 1 matrix holding a copy of v.
func ColVector(v []float64) *Matrix {
	m := New(len(v), 1)
	copy(m.Data, v)
	return m
}

// Scalar returns a 1 x 1 matrix holding v.
func Scalar(v float64) *Matrix {
	return &Matrix{Rows: 1, Cols: 1, Data: []float64{v}}
}
