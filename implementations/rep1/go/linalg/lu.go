package linalg

import "math"

// LU holds a factorisation P A = L U of a square matrix computed by
// right-looking Gaussian elimination with partial pivoting (ties go to the
// smallest row index).
type LU struct {
	n     int
	lu    []float64 // packed: multipliers below the diagonal, U on and above
	perm  []int     // perm[i] = original row now in row i
	swaps int       // number of row interchanges performed
}

// factorLU eliminates a copy of a. It stops at the first exactly-zero pivot
// and reports singular == true (the returned factors are then incomplete).
func factorLU(a *Matrix) (f *LU, singular bool) {
	n := a.Rows
	f = &LU{n: n, lu: append([]float64(nil), a.Data...), perm: make([]int, n)}
	for i := range f.perm {
		f.perm[i] = i
	}
	m := f.lu
	for k := 0; k < n; k++ {
		p, best := k, math.Abs(m[k*n+k])
		for i := k + 1; i < n; i++ {
			if v := math.Abs(m[i*n+k]); v > best {
				p, best = i, v
			}
		}
		if best == 0 {
			return f, true
		}
		if p != k {
			rk, rp := m[k*n:(k+1)*n], m[p*n:(p+1)*n]
			for j := range rk {
				rk[j], rp[j] = rp[j], rk[j]
			}
			f.perm[k], f.perm[p] = f.perm[p], f.perm[k]
			f.swaps++
		}
		rk := m[k*n+k+1 : (k+1)*n]
		piv := m[k*n+k]
		for i := k + 1; i < n; i++ {
			ri := m[i*n : (i+1)*n]
			fac := ri[k] / piv
			ri[k] = fac
			if fac == 0 {
				continue
			}
			rij := ri[k+1:]
			for j, v := range rk {
				rij[j] -= fac * v
			}
		}
	}
	return f, false
}

// NewLU factors the square matrix a. It returns ErrNotSquare for a non-square
// matrix and ErrSingular if a pivot is exactly zero.
func NewLU(a *Matrix) (*LU, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	f, singular := factorLU(a)
	if singular {
		return nil, ErrSingular
	}
	return f, nil
}

// Perm returns the row permutation: Perm()[i] is the index in the original
// matrix of the row now in row i.
func (f *LU) Perm() []int { return append([]int(nil), f.perm...) }

// P returns the permutation matrix with P[i][perm[i]] = 1, so P A = L U.
func (f *LU) P() *Matrix {
	p := New(f.n, f.n)
	for i, j := range f.perm {
		p.Data[i*f.n+j] = 1
	}
	return p
}

// L returns the unit lower triangular factor.
func (f *LU) L() *Matrix {
	n := f.n
	l := New(n, n)
	for i := 0; i < n; i++ {
		copy(l.Data[i*n:i*n+i], f.lu[i*n:i*n+i])
		l.Data[i*n+i] = 1
	}
	return l
}

// U returns the upper triangular factor.
func (f *LU) U() *Matrix {
	n := f.n
	u := New(n, n)
	for i := 0; i < n; i++ {
		copy(u.Data[i*n+i:(i+1)*n], f.lu[i*n+i:(i+1)*n])
	}
	return u
}

// Det returns the determinant: the product of U's diagonal in increasing
// order, negated when the number of row swaps is odd.
func (f *LU) Det() float64 {
	d := 1.0
	for i := 0; i < f.n; i++ {
		d *= f.lu[i*f.n+i]
	}
	if f.swaps%2 == 1 {
		d = -d
	}
	return d
}

// Solve returns X with A X = B for an n x k right-hand side, solving all
// columns at once (row-axpy substitution; each entry sees the same operations
// as a per-column solve). It returns ErrDimensionMismatch if B has the wrong
// number of rows.
func (f *LU) Solve(b *Matrix) (*Matrix, error) {
	n := f.n
	if b.Rows != n {
		return nil, ErrDimensionMismatch
	}
	k := b.Cols
	x := New(n, k)
	for i, src := range f.perm {
		copy(x.Row(i), b.Row(src))
	}
	for i := 1; i < n; i++ {
		xi := x.Row(i)
		li := f.lu[i*n : i*n+i]
		for j, l := range li {
			if l == 0 {
				continue
			}
			for c, v := range x.Row(j) {
				xi[c] -= l * v
			}
		}
	}
	for i := n - 1; i >= 0; i-- {
		xi := x.Row(i)
		ui := f.lu[i*n : (i+1)*n]
		for j := i + 1; j < n; j++ {
			u := ui[j]
			if u == 0 {
				continue
			}
			for c, v := range x.Row(j) {
				xi[c] -= u * v
			}
		}
		d := ui[i]
		for c := range xi {
			xi[c] /= d
		}
	}
	return x, nil
}

// Det returns the determinant of a square matrix. A zero pivot yields 0.0;
// the only error is ErrNotSquare.
func Det(a *Matrix) (float64, error) {
	if !a.IsSquare() {
		return 0, ErrNotSquare
	}
	f, singular := factorLU(a)
	if singular {
		return 0, nil
	}
	return f.Det(), nil
}

// Solve returns X with A X = B. A must be square (ErrNotSquare, checked
// first), B must have as many rows as A (ErrDimensionMismatch), and A must be
// nonsingular (ErrSingular).
func Solve(a, b *Matrix) (*Matrix, error) {
	if !a.IsSquare() {
		return nil, ErrNotSquare
	}
	if b.Rows != a.Rows {
		return nil, ErrDimensionMismatch
	}
	f, err := NewLU(a)
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
