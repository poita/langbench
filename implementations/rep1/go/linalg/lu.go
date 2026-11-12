package linalg

// LUFactors is the result of LU factorisation with partial pivoting,
// P A = L U.
type LUFactors struct {
	// LU holds L strictly below the diagonal (its unit diagonal is implicit)
	// and U on and above the diagonal.
	LU *Matrix
	// Perm[i] is the row of the original matrix now sitting in row i.
	Perm []int
	// Swaps is the number of row interchanges performed.
	Swaps int
}

// eliminate runs right-looking Gaussian elimination with partial pivoting on
// a copy of the square matrix a. If an exactly zero pivot is met it returns
// ok == false.
func eliminate(a *Matrix) (f *LUFactors, ok bool) {
	n := a.Rows
	m := a.Clone()
	perm := make([]int, n)
	for i := range perm {
		perm[i] = i
	}
	swaps := 0
	d := m.Data
	for k := 0; k < n; k++ {
		p, best := k, abs(d[k*n+k])
		for i := k + 1; i < n; i++ {
			if v := abs(d[i*n+k]); v > best {
				p, best = i, v
			}
		}
		if best == 0 {
			return &LUFactors{LU: m, Perm: perm, Swaps: swaps}, false
		}
		if p != k {
			rk, rp := d[k*n:(k+1)*n], d[p*n:(p+1)*n]
			for j := range rk {
				rk[j], rp[j] = rp[j], rk[j]
			}
			perm[k], perm[p] = perm[p], perm[k]
			swaps++
		}
		rk := d[k*n : (k+1)*n]
		pivot := rk[k]
		for i := k + 1; i < n; i++ {
			ri := d[i*n : (i+1)*n]
			f := ri[k] / pivot
			ri[k] = f
			for j := k + 1; j < n; j++ {
				ri[j] -= float64(f * rk[j])
			}
		}
	}
	return &LUFactors{LU: m, Perm: perm, Swaps: swaps}, true
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// LU factors the square matrix a as P A = L U. It returns ErrNotSquare for a
// non-square matrix and ErrSingular if an exactly zero pivot is met.
func LU(a *Matrix) (*LUFactors, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	f, ok := eliminate(a)
	if !ok {
		return nil, ErrSingular
	}
	return f, nil
}

// P returns the permutation matrix with P[i][Perm[i]] = 1.
func (f *LUFactors) P() *Matrix {
	n := len(f.Perm)
	p := New(n, n)
	for i, j := range f.Perm {
		p.Data[i*n+j] = 1
	}
	return p
}

// L returns the unit lower triangular factor.
func (f *LUFactors) L() *Matrix {
	n := len(f.Perm)
	l := New(n, n)
	for i := 0; i < n; i++ {
		for j := 0; j < i; j++ {
			l.Data[i*n+j] = f.LU.Data[i*n+j]
		}
		l.Data[i*n+i] = 1
	}
	return l
}

// U returns the upper triangular factor.
func (f *LUFactors) U() *Matrix {
	n := len(f.Perm)
	u := New(n, n)
	for i := 0; i < n; i++ {
		for j := i; j < n; j++ {
			u.Data[i*n+j] = f.LU.Data[i*n+j]
		}
	}
	return u
}

// Solve solves A X = B using the factorisation, one column of B at a time:
// permute, forward substitution through L, back substitution through U.
// B must have as many rows as A.
func (f *LUFactors) Solve(b *Matrix) (*Matrix, error) {
	n := len(f.Perm)
	if b.Rows != n {
		return nil, ErrDimensionMismatch
	}
	lu := f.LU.Data
	x := New(n, b.Cols)
	col := make([]float64, n)
	for c := 0; c < b.Cols; c++ {
		for i := 0; i < n; i++ {
			col[i] = b.Data[f.Perm[i]*b.Cols+c]
		}
		for i := 0; i < n; i++ {
			s := col[i]
			row := lu[i*n : i*n+i]
			for j, l := range row {
				s -= float64(l * col[j])
			}
			col[i] = s
		}
		for i := n - 1; i >= 0; i-- {
			s := col[i]
			for j := i + 1; j < n; j++ {
				s -= float64(lu[i*n+j] * col[j])
			}
			col[i] = s / lu[i*n+i]
		}
		for i := 0; i < n; i++ {
			x.Data[i*b.Cols+c] = col[i]
		}
	}
	return x, nil
}

// Det returns the determinant of the square matrix a. A zero pivot yields
// exactly 0 rather than an error.
func Det(a *Matrix) (float64, error) {
	if !a.IsSquare() {
		return 0, ErrNotSquare
	}
	f, ok := eliminate(a)
	if !ok {
		return 0, nil
	}
	n := a.Rows
	det := 1.0
	for i := 0; i < n; i++ {
		det *= f.LU.Data[i*n+i]
	}
	if f.Swaps%2 == 1 {
		det = -det
	}
	return det, nil
}

// Solve solves A X = B. The checks are applied in order: A square
// (ErrNotSquare), B's row count (ErrDimensionMismatch), then singularity
// (ErrSingular).
func Solve(a, b *Matrix) (*Matrix, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	if b.Rows != a.Rows {
		return nil, ErrDimensionMismatch
	}
	f, err := LU(a)
	if err != nil {
		return nil, err
	}
	return f.Solve(b)
}

// Inverse returns A⁻¹, computed as Solve(A, I).
func Inverse(a *Matrix) (*Matrix, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	return Solve(a, Identity(a.Rows))
}
