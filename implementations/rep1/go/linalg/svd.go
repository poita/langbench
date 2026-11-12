package linalg

import "math"

// SVDFactors is a thin singular value decomposition A = U diag(S) Vᵀ with
// k = min(m, n).
type SVDFactors struct {
	U *Matrix   // m x k, orthonormal columns
	S []float64 // k singular values, descending, non-negative
	V *Matrix   // n x k, orthonormal columns
}

// SVD computes the thin SVD of an m x n matrix with one-sided Jacobi. If
// m < n the algorithm runs on Aᵀ and the roles of U and V are swapped.
// Columns of U are sign-normalised (the matching column of V follows).
func SVD(a *Matrix) *SVDFactors {
	if a.Rows < a.Cols {
		f := svdTall(Transpose(a))
		f.U, f.V = f.V, f.U
		normaliseSVDSigns(f)
		return f
	}
	f := svdTall(a)
	normaliseSVDSigns(f)
	return f
}

func normaliseSVDSigns(f *SVDFactors) {
	k := len(f.S)
	for j := 0; j < k; j++ {
		if signNormalise(f.U.Data, f.U.Rows, k, j) {
			for i := 0; i < f.V.Rows; i++ {
				f.V.Data[i*k+j] = -f.V.Data[i*k+j]
			}
		}
	}
}

// svdTall runs one-sided Jacobi on a matrix with Rows >= Cols and returns
// the sorted, unsign-normalised factors.
func svdTall(a *Matrix) *SVDFactors {
	m, n := a.Rows, a.Cols
	// W and V are held column-wise: w[j] is column j.
	w := make([][]float64, n)
	v := make([][]float64, n)
	for j := 0; j < n; j++ {
		w[j] = make([]float64, m)
		for i := 0; i < m; i++ {
			w[j][i] = a.Data[i*n+j]
		}
		v[j] = make([]float64, n)
		v[j][j] = 1
	}
	for sweep := 0; sweep < maxSweeps; sweep++ {
		rotated := false
		for p := 0; p < n-1; p++ {
			for q := p + 1; q < n; q++ {
				wp, wq := w[p], w[q]
				var alpha, beta, gamma float64
				for i := range wp {
					x, y := wp[i], wq[i]
					alpha += float64(x * x)
					beta += float64(y * y)
					gamma += float64(x * y)
				}
				if gamma == 0 || alpha == 0 || beta == 0 ||
					abs(gamma) <= 1e-14*math.Sqrt(float64(alpha*beta)) {
					continue
				}
				c, s := jacobiRotation((beta - alpha) / (2 * gamma))
				rotate(wp, wq, c, s)
				rotate(v[p], v[q], c, s)
				rotated = true
			}
		}
		if !rotated {
			break
		}
	}

	sigma := make([]float64, n)
	for j := 0; j < n; j++ {
		s := 0.0
		for _, x := range w[j] {
			s += float64(x * x)
		}
		sigma[j] = math.Sqrt(s)
	}
	idx := order(sigma, true)
	f := &SVDFactors{U: New(m, n), S: make([]float64, n), V: New(n, n)}
	for j, src := range idx {
		f.S[j] = sigma[src]
		for i := 0; i < m; i++ {
			if sigma[src] != 0 {
				f.U.Data[i*n+j] = w[src][i] / sigma[src]
			}
		}
		for i := 0; i < n; i++ {
			f.V.Data[i*n+j] = v[src][i]
		}
	}
	return f
}

// rotate applies x, y ← c x − s y, s x + c y elementwise.
func rotate(x, y []float64, c, s float64) {
	y = y[:len(x)]
	for i := range x {
		a, b := x[i], y[i]
		x[i] = float64(c*a) - float64(s*b)
		y[i] = float64(s*a) + float64(c*b)
	}
}

// Cond returns σ_max / σ_min of any matrix, or ErrSingular if the smallest
// singular value is exactly zero.
func Cond(a *Matrix) (float64, error) {
	f := SVD(a)
	smin := f.S[len(f.S)-1]
	if smin == 0 {
		return 0, ErrSingular
	}
	return f.S[0] / smin, nil
}
