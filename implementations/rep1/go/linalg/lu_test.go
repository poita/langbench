package linalg_test

import (
	"testing"

	"linalg"
)

func TestLUFactorisation(t *testing.T) {
	a := randMat(1, 12, 12)
	f, err := linalg.NewLU(a)
	if err != nil {
		t.Fatal(err)
	}
	pa := mustMul(t, f.P(), a)
	near(t, mustMul(t, f.L(), f.U()), pa, 1e-13)
	l := f.L()
	for i := 0; i < 12; i++ {
		for j := 0; j < 12; j++ {
			if j > i && l.At(i, j) != 0 || j == i && l.At(i, j) != 1 || l.At(i, j) > 1 || l.At(i, j) < -1 {
				t.Fatalf("bad L[%d][%d] = %v", i, j, l.At(i, j))
			}
		}
	}
}

func TestPivotTieGoesToSmallestIndex(t *testing.T) {
	a := mat(t, []float64{1, 2}, []float64{-1, 3})
	f, err := linalg.NewLU(a)
	if err != nil {
		t.Fatal(err)
	}
	if p := f.Perm(); p[0] != 0 || p[1] != 1 {
		t.Errorf("perm = %v", p)
	}
}

func TestDet(t *testing.T) {
	d, err := linalg.Det(mat(t, []float64{1, 2}, []float64{3, 4}))
	if err != nil || d < -2.0000000001 || d > -1.9999999999 {
		t.Errorf("det = %v, %v", d, err)
	}
	d, err = linalg.Det(mat(t, []float64{1, 2}, []float64{2, 4}))
	if err != nil || d != 0 {
		t.Errorf("singular det = %v, %v", d, err)
	}
	_, err = linalg.Det(linalg.New(2, 3))
	wantErr(t, err, linalg.ErrNotSquare)
}

func TestSolveInverse(t *testing.T) {
	a := randMat(2, 20, 20)
	b := randMat(3, 20, 3)
	x, err := linalg.Solve(a, b)
	if err != nil {
		t.Fatal(err)
	}
	near(t, mustMul(t, a, x), b, 1e-10)
	inv, err := linalg.Inverse(a)
	if err != nil {
		t.Fatal(err)
	}
	near(t, mustMul(t, a, inv), linalg.Identity(20), 1e-10)
}

func TestSolveErrors(t *testing.T) {
	_, err := linalg.Solve(linalg.New(2, 3), linalg.New(3, 1))
	wantErr(t, err, linalg.ErrNotSquare)
	_, err = linalg.Solve(linalg.Identity(2), linalg.New(3, 1))
	wantErr(t, err, linalg.ErrDimensionMismatch)
	_, err = linalg.Solve(linalg.New(2, 2), linalg.New(2, 1))
	wantErr(t, err, linalg.ErrSingular)
	_, err = linalg.Inverse(linalg.New(2, 3))
	wantErr(t, err, linalg.ErrNotSquare)
	_, err = linalg.NewLU(linalg.New(3, 3))
	wantErr(t, err, linalg.ErrSingular)
}
