package linalg_test

import (
	"errors"
	"math"
	"math/rand"
	"testing"

	"example.com/linalg"
)

func randMatrix(rng *rand.Rand, m, n int) *linalg.Matrix {
	a := linalg.New(m, n)
	for i := range a.Data {
		a.Data[i] = rng.NormFloat64()
	}
	return a
}

func maxDiff(a, b *linalg.Matrix) float64 {
	if a.Rows != b.Rows || a.Cols != b.Cols {
		return math.Inf(1)
	}
	d := 0.0
	for i := range a.Data {
		d = math.Max(d, math.Abs(a.Data[i]-b.Data[i]))
	}
	return d
}

func mustMul(t *testing.T, a, b *linalg.Matrix) *linalg.Matrix {
	t.Helper()
	c, err := linalg.Mul(a, b)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func near(t *testing.T, name string, a, b *linalg.Matrix, tol float64) {
	t.Helper()
	if d := maxDiff(a, b); !(d <= tol) {
		t.Errorf("%s: max difference %g > %g", name, d, tol)
	}
}

func TestAddMulTranspose(t *testing.T) {
	a := linalg.FromRows([][]float64{{1, 2, 3}, {4, 5, 6}})
	b := linalg.FromRows([][]float64{{1, 0}, {0, 1}, {1, 1}})
	c := mustMul(t, a, b)
	near(t, "mul", c, linalg.FromRows([][]float64{{4, 5}, {10, 11}}), 0)
	near(t, "transpose", linalg.Transpose(a), linalg.FromRows([][]float64{{1, 4}, {2, 5}, {3, 6}}), 0)
	s, err := linalg.Add(a, a)
	if err != nil {
		t.Fatal(err)
	}
	near(t, "add", s, linalg.FromRows([][]float64{{2, 4, 6}, {8, 10, 12}}), 0)
	if _, err := linalg.Add(a, b); !errors.Is(err, linalg.ErrDimensionMismatch) {
		t.Errorf("add mismatch: got %v", err)
	}
	if _, err := linalg.Mul(a, a); !errors.Is(err, linalg.ErrDimensionMismatch) {
		t.Errorf("mul mismatch: got %v", err)
	}
}

func TestNorms(t *testing.T) {
	a := linalg.FromRows([][]float64{{1, -2}, {-3, 4}})
	if got := linalg.Norm1(a); got != 6 {
		t.Errorf("norm1 = %g", got)
	}
	if got := linalg.NormInf(a); got != 7 {
		t.Errorf("norminf = %g", got)
	}
	if got := linalg.NormFro(a); math.Abs(got-math.Sqrt(30)) > 1e-15 {
		t.Errorf("normfro = %g", got)
	}
}

func TestLUDetSolveInverse(t *testing.T) {
	a := linalg.FromRows([][]float64{{1, 2}, {3, 4}})
	d, err := linalg.Det(a)
	if err != nil || math.Abs(d+2) > 1e-14 {
		t.Errorf("det = %g, %v", d, err)
	}
	f, err := linalg.LU(a)
	if err != nil {
		t.Fatal(err)
	}
	if f.Perm[0] != 1 || f.Perm[1] != 0 || f.Swaps != 1 {
		t.Errorf("perm = %v swaps = %d", f.Perm, f.Swaps)
	}
	rng := rand.New(rand.NewSource(1))
	for _, n := range []int{1, 2, 5, 30} {
		a := randMatrix(rng, n, n)
		f, err := linalg.LU(a)
		if err != nil {
			t.Fatal(err)
		}
		near(t, "PA=LU", mustMul(t, f.P(), a), mustMul(t, f.L(), f.U()), 1e-12)
		inv, err := linalg.Inverse(a)
		if err != nil {
			t.Fatal(err)
		}
		near(t, "A*inv=I", mustMul(t, a, inv), linalg.Identity(n), 1e-8)
		b := randMatrix(rng, n, 3)
		x, err := linalg.Solve(a, b)
		if err != nil {
			t.Fatal(err)
		}
		near(t, "AX=B", mustMul(t, a, x), b, 1e-8)
	}
}

func TestLUErrors(t *testing.T) {
	sing := linalg.FromRows([][]float64{{1, 2}, {2, 4}})
	if _, err := linalg.LU(sing); !errors.Is(err, linalg.ErrSingular) {
		t.Errorf("lu singular: %v", err)
	}
	if _, err := linalg.Inverse(sing); !errors.Is(err, linalg.ErrSingular) {
		t.Errorf("inv singular: %v", err)
	}
	if d, err := linalg.Det(sing); err != nil || d != 0 {
		t.Errorf("det singular = %g, %v", d, err)
	}
	rect := linalg.New(2, 3)
	if _, err := linalg.Inverse(rect); !errors.Is(err, linalg.ErrNotSquare) {
		t.Errorf("inv rect: %v", err)
	}
	// not_square wins over dimension_mismatch.
	if _, err := linalg.Solve(rect, linalg.New(3, 1)); !errors.Is(err, linalg.ErrNotSquare) {
		t.Errorf("solve rect: %v", err)
	}
	if _, err := linalg.Solve(sing, linalg.New(3, 1)); !errors.Is(err, linalg.ErrDimensionMismatch) {
		t.Errorf("solve rhs: %v", err)
	}
}

func TestQR(t *testing.T) {
	f, err := linalg.QR(linalg.FromRows([][]float64{{3}, {4}}))
	if err != nil {
		t.Fatal(err)
	}
	near(t, "Q", f.Q, linalg.FromRows([][]float64{{0.6}, {0.8}}), 1e-15)
	near(t, "R", f.R, linalg.FromRows([][]float64{{5}}), 1e-15)

	rng := rand.New(rand.NewSource(2))
	for _, sh := range [][2]int{{1, 1}, {5, 5}, {9, 4}, {40, 12}} {
		a := randMatrix(rng, sh[0], sh[1])
		f, err := linalg.QR(a)
		if err != nil {
			t.Fatal(err)
		}
		near(t, "QR=A", mustMul(t, f.Q, f.R), a, 1e-12)
		near(t, "QtQ=I", mustMul(t, linalg.Transpose(f.Q), f.Q), linalg.Identity(sh[1]), 1e-12)
		for i := 0; i < sh[1]; i++ {
			if f.R.At(i, i) < 0 {
				t.Errorf("negative R diagonal")
			}
			for j := 0; j < i; j++ {
				if f.R.At(i, j) != 0 {
					t.Errorf("R not triangular")
				}
			}
		}
	}
	// A zero column is handled; QR still succeeds.
	if _, err := linalg.QR(linalg.FromRows([][]float64{{0, 1}, {0, 2}, {0, 3}})); err != nil {
		t.Errorf("rank deficient qr: %v", err)
	}
	if _, err := linalg.QR(linalg.New(2, 3)); !errors.Is(err, linalg.ErrDimensionMismatch) {
		t.Errorf("wide qr: %v", err)
	}
}

func TestLeastSquares(t *testing.T) {
	// Fit y = 1 + 2x exactly through noisy-free points.
	a := linalg.FromRows([][]float64{{1, 0}, {1, 1}, {1, 2}, {1, 3}})
	b := linalg.FromRows([][]float64{{1}, {3}, {5}, {7}})
	x, err := linalg.LeastSquares(a, b)
	if err != nil {
		t.Fatal(err)
	}
	near(t, "x", x, linalg.FromRows([][]float64{{1}, {2}}), 1e-12)
	if _, err := linalg.LeastSquares(a, linalg.New(3, 1)); !errors.Is(err, linalg.ErrDimensionMismatch) {
		t.Errorf("rhs rows: %v", err)
	}
	def := linalg.FromRows([][]float64{{0, 1}, {0, 2}, {0, 3}})
	if _, err := linalg.LeastSquares(def, linalg.New(3, 1)); !errors.Is(err, linalg.ErrSingular) {
		t.Errorf("rank deficient: %v", err)
	}
}

func TestCholesky(t *testing.T) {
	l, err := linalg.Cholesky(linalg.FromRows([][]float64{{4, 2}, {2, 5}}))
	if err != nil {
		t.Fatal(err)
	}
	near(t, "L", l, linalg.FromRows([][]float64{{2, 0}, {1, 2}}), 1e-15)

	rng := rand.New(rand.NewSource(3))
	g := randMatrix(rng, 20, 20)
	spd := mustMul(t, g, linalg.Transpose(g))
	for i := 0; i < 20; i++ {
		spd.Set(i, i, spd.At(i, i)+1)
	}
	l, err = linalg.Cholesky(spd)
	if err != nil {
		t.Fatal(err)
	}
	near(t, "LLt=A", mustMul(t, l, linalg.Transpose(l)), spd, 1e-11)

	if _, err := linalg.Cholesky(linalg.New(2, 3)); !errors.Is(err, linalg.ErrNotSquare) {
		t.Errorf("rect: %v", err)
	}
	if _, err := linalg.Cholesky(linalg.FromRows([][]float64{{1, 2}, {3, 4}})); !errors.Is(err, linalg.ErrNotSymmetric) {
		t.Errorf("asym: %v", err)
	}
	if _, err := linalg.Cholesky(linalg.FromRows([][]float64{{1, 2}, {2, 1}})); !errors.Is(err, linalg.ErrNotPositiveDefinite) {
		t.Errorf("indefinite: %v", err)
	}
}

func TestSymEigen(t *testing.T) {
	w, v, err := linalg.SymEigen(linalg.FromRows([][]float64{{2, 1}, {1, 3}}))
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(w[0]-(5-math.Sqrt(5))/2) > 1e-14 || math.Abs(w[1]-(5+math.Sqrt(5))/2) > 1e-14 {
		t.Errorf("w = %v", w)
	}
	near(t, "V", v, linalg.FromRows([][]float64{{0.8506508084, 0.5257311121}, {-0.5257311121, 0.8506508084}}), 1e-9)

	rng := rand.New(rand.NewSource(4))
	for _, n := range []int{1, 3, 12, 40} {
		g := randMatrix(rng, n, n)
		a, _ := linalg.Add(g, linalg.Transpose(g))
		w, v, err := linalg.SymEigen(a)
		if err != nil {
			t.Fatal(err)
		}
		d := linalg.New(n, n)
		for i, x := range w {
			d.Set(i, i, x)
			if i > 0 && w[i-1] > x {
				t.Errorf("eigenvalues not ascending")
			}
		}
		near(t, "AV=VW", mustMul(t, a, v), mustMul(t, v, d), 1e-11)
		near(t, "VtV=I", mustMul(t, linalg.Transpose(v), v), linalg.Identity(n), 1e-12)
	}
	if _, _, err := linalg.SymEigen(linalg.FromRows([][]float64{{1, 2}, {3, 4}})); !errors.Is(err, linalg.ErrNotSymmetric) {
		t.Errorf("asym: %v", err)
	}
	if _, _, err := linalg.SymEigen(linalg.New(2, 3)); !errors.Is(err, linalg.ErrNotSquare) {
		t.Errorf("rect: %v", err)
	}
}

func TestSVD(t *testing.T) {
	rng := rand.New(rand.NewSource(5))
	for _, sh := range [][2]int{{1, 1}, {4, 4}, {9, 3}, {3, 9}, {1, 5}, {20, 20}} {
		a := randMatrix(rng, sh[0], sh[1])
		f := linalg.SVD(a)
		k := min(sh[0], sh[1])
		if f.U.Rows != sh[0] || f.U.Cols != k || f.V.Rows != sh[1] || f.V.Cols != k || len(f.S) != k {
			t.Fatalf("%v: bad shapes", sh)
		}
		s := linalg.New(k, k)
		for i, x := range f.S {
			s.Set(i, i, x)
			if i > 0 && f.S[i-1] < x {
				t.Errorf("singular values not descending")
			}
		}
		rec := mustMul(t, mustMul(t, f.U, s), linalg.Transpose(f.V))
		near(t, "USVt=A", rec, a, 1e-12)
		near(t, "UtU=I", mustMul(t, linalg.Transpose(f.U), f.U), linalg.Identity(k), 1e-12)
		near(t, "VtV=I", mustMul(t, linalg.Transpose(f.V), f.V), linalg.Identity(k), 1e-12)
	}
}

func TestCond(t *testing.T) {
	c, err := linalg.Cond(linalg.FromRows([][]float64{{3, 0}, {0, -1}}))
	if err != nil || math.Abs(c-3) > 1e-14 {
		t.Errorf("cond = %g, %v", c, err)
	}
	if _, err := linalg.Cond(linalg.FromRows([][]float64{{1, 1}, {1, 1}})); !errors.Is(err, linalg.ErrSingular) {
		t.Errorf("singular cond: %v", err)
	}
}

func TestErrorCode(t *testing.T) {
	if c, ok := linalg.ErrorCode(linalg.ErrNotSquare); !ok || c != "not_square" {
		t.Errorf("got %q %v", c, ok)
	}
	if _, ok := linalg.ErrorCode(errors.New("other")); ok {
		t.Errorf("foreign error recognised")
	}
}

func ExampleSolve() {
	a := linalg.FromRows([][]float64{{2, 0}, {0, 4}})
	b := linalg.FromRows([][]float64{{2}, {2}})
	x, _ := linalg.Solve(a, b)
	_ = x // x = [[1], [0.5]]
}
