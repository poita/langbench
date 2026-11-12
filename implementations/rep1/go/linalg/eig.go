package linalg

import "math"

// SymEigen computes the eigendecomposition A = V diag(w) Vᵀ of a symmetric
// matrix with the cyclic Jacobi method. The eigenvalues w are ascending and
// column j of V is the unit eigenvector for w[j], sign-normalised so that its
// first largest-magnitude component is positive.
//
// It returns ErrNotSquare or ErrNotSymmetric (exact comparison) for invalid
// input.
func SymEigen(a *Matrix) (w []float64, v *Matrix, err error) {
	if !a.IsSquare() {
		return nil, nil, ErrNotSquare
	}
	if !a.IsSymmetric() {
		return nil, nil, ErrNotSymmetric
	}
	n := a.Rows
	m := a.Clone()
	md := m.Data
	vm := Identity(n)
	vd := vm.Data
	phi := NormFro(a)

	offNorm := func() float64 {
		s := 0.0
		for i := 0; i < n; i++ {
			for j := i + 1; j < n; j++ {
				x := md[i*n+j]
				s += float64(x * x)
			}
		}
		return math.Sqrt(2 * s)
	}

	prev := math.Inf(1)
	for sweep := 0; sweep < maxSweeps; sweep++ {
		off := offNorm()
		if off <= 1e-14*phi || off >= prev {
			break
		}
		prev = off
		for p := 0; p < n-1; p++ {
			for q := p + 1; q < n; q++ {
				apq := md[p*n+q]
				if apq == 0 {
					continue
				}
				theta := (md[q*n+q] - md[p*n+p]) / (2 * apq)
				c, s := jacobiRotation(theta)
				for i := 0; i < n; i++ {
					x, y := md[i*n+p], md[i*n+q]
					md[i*n+p] = float64(c*x) - float64(s*y)
					md[i*n+q] = float64(s*x) + float64(c*y)
				}
				rp, rq := md[p*n:(p+1)*n], md[q*n:(q+1)*n]
				for j := 0; j < n; j++ {
					x, y := rp[j], rq[j]
					rp[j] = float64(c*x) - float64(s*y)
					rq[j] = float64(s*x) + float64(c*y)
				}
				md[p*n+q], md[q*n+p] = 0, 0
				for i := 0; i < n; i++ {
					x, y := vd[i*n+p], vd[i*n+q]
					vd[i*n+p] = float64(c*x) - float64(s*y)
					vd[i*n+q] = float64(s*x) + float64(c*y)
				}
			}
		}
	}

	diag := make([]float64, n)
	for i := range diag {
		diag[i] = md[i*n+i]
	}
	idx := order(diag, false)
	w = make([]float64, n)
	vs := New(n, n)
	for j, src := range idx {
		w[j] = diag[src]
		for i := 0; i < n; i++ {
			vs.Data[i*n+j] = vd[i*n+src]
		}
	}
	for j := 0; j < n; j++ {
		signNormalise(vs.Data, n, n, j)
	}
	return w, vs, nil
}
