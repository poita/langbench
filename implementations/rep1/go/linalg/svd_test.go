package linalg_test

import (
	"math"
	"testing"

	"linalg"
)

func checkSVD(t *testing.T, a *linalg.Matrix) {
	t.Helper()
	f := linalg.SVD(a)
	k := len(f.S)
	if f.U.Rows != a.Rows || f.U.Cols != k || f.V.Rows != a.Cols || f.V.Cols != k {
		t.Fatalf("bad shapes U %dx%d V %dx%d k=%d", f.U.Rows, f.U.Cols, f.V.Rows, f.V.Cols, k)
	}
	d := linalg.New(k, k)
	for i, s := range f.S {
		d.Set(i, i, s)
		if i > 0 && s > f.S[i-1] {
			t.Fatal("singular values not descending")
		}
	}
	near(t, mustMul(t, mustMul(t, f.U, d), linalg.Transpose(f.V)), a, 1e-12)
	near(t, mustMul(t, linalg.Transpose(f.U), f.U), linalg.Identity(k), 1e-12)
	near(t, mustMul(t, linalg.Transpose(f.V), f.V), linalg.Identity(k), 1e-12)
}

func TestSVDShapes(t *testing.T) {
	checkSVD(t, randMat(7, 10, 4))
	checkSVD(t, randMat(8, 4, 10))
	checkSVD(t, randMat(9, 7, 7))
	checkSVD(t, randMat(10, 1, 5))
	checkSVD(t, randMat(11, 5, 1))
}

func TestSVDKnownValues(t *testing.T) {
	f := linalg.SVD(mat(t, []float64{3, 0}, []float64{0, -2}))
	if math.Abs(f.S[0]-3) > 1e-15 || math.Abs(f.S[1]-2) > 1e-15 {
		t.Errorf("S = %v", f.S)
	}
}

func TestSingularValuesAndCond(t *testing.T) {
	a := randMat(12, 8, 5)
	sv := linalg.SingularValues(a)
	full := linalg.SVD(a).S
	for i := range sv {
		if sv[i] != full[i] {
			t.Fatalf("SingularValues differ from SVD at %d: %v vs %v", i, sv[i], full[i])
		}
	}
	c, err := linalg.Cond(mat(t, []float64{4, 0}, []float64{0, 2}))
	if err != nil || math.Abs(c-2) > 1e-14 {
		t.Errorf("cond = %v, %v", c, err)
	}
	_, err = linalg.Cond(linalg.New(2, 2))
	wantErr(t, err, linalg.ErrSingular)
}
