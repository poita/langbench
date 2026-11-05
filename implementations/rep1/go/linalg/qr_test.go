package linalg_test

import (
	"testing"

	"linalg"
)

func TestQR(t *testing.T) {
	a := randMat(4, 15, 6)
	f, err := linalg.QR(a)
	if err != nil {
		t.Fatal(err)
	}
	near(t, mustMul(t, f.Q, f.R), a, 1e-13)
	near(t, mustMul(t, linalg.Transpose(f.Q), f.Q), linalg.Identity(6), 1e-13)
	for i := 0; i < 6; i++ {
		if f.R.At(i, i) < 0 {
			t.Errorf("negative diagonal R[%d]", i)
		}
		for j := 0; j < i; j++ {
			if f.R.At(i, j) != 0 {
				t.Errorf("R[%d][%d] != 0", i, j)
			}
		}
	}
}

func TestQRSignConvention(t *testing.T) {
	f, err := linalg.QR(mat(t, []float64{3}, []float64{4}))
	if err != nil {
		t.Fatal(err)
	}
	near(t, f.Q, mat(t, []float64{0.6}, []float64{0.8}), 1e-15)
	near(t, f.R, mat(t, []float64{5}), 1e-15)
}

func TestQRRankDeficient(t *testing.T) {
	a := mat(t, []float64{1, 0}, []float64{2, 0}, []float64{3, 0})
	f, err := linalg.QR(a)
	if err != nil {
		t.Fatal(err)
	}
	near(t, mustMul(t, f.Q, f.R), a, 1e-14)
	_, err = linalg.LeastSquares(a, linalg.New(3, 1))
	wantErr(t, err, linalg.ErrSingular)
}

func TestQRShape(t *testing.T) {
	_, err := linalg.QR(linalg.New(2, 3))
	wantErr(t, err, linalg.ErrDimensionMismatch)
}

func TestLeastSquares(t *testing.T) {
	// Fit y = 1 + 2x exactly through noiseless points.
	a := mat(t, []float64{1, 0}, []float64{1, 1}, []float64{1, 2}, []float64{1, 3})
	b := mat(t, []float64{1}, []float64{3}, []float64{5}, []float64{7})
	x, err := linalg.LeastSquares(a, b)
	if err != nil {
		t.Fatal(err)
	}
	near(t, x, mat(t, []float64{1}, []float64{2}), 1e-13)
	_, err = linalg.LeastSquares(a, linalg.New(3, 1))
	wantErr(t, err, linalg.ErrDimensionMismatch)
	_, err = linalg.LeastSquares(linalg.New(2, 3), linalg.New(2, 1))
	wantErr(t, err, linalg.ErrDimensionMismatch)
}
