package linalg_test

import (
	"testing"

	"linalg"
)

func TestCholesky(t *testing.T) {
	l, err := linalg.Cholesky(mat(t, []float64{4, 2}, []float64{2, 5}))
	if err != nil {
		t.Fatal(err)
	}
	near(t, l, mat(t, []float64{2, 0}, []float64{1, 2}), 1e-15)

	g := randMat(5, 9, 9)
	spd := mustMul(t, linalg.Transpose(g), g)
	for i := 0; i < 9; i++ {
		spd.Set(i, i, spd.At(i, i)+1)
	}
	// Make exactly symmetric.
	for i := 0; i < 9; i++ {
		for j := 0; j < i; j++ {
			spd.Set(i, j, spd.At(j, i))
		}
	}
	l, err = linalg.Cholesky(spd)
	if err != nil {
		t.Fatal(err)
	}
	near(t, mustMul(t, l, linalg.Transpose(l)), spd, 1e-12)
}

func TestCholeskyErrors(t *testing.T) {
	_, err := linalg.Cholesky(linalg.New(2, 3))
	wantErr(t, err, linalg.ErrNotSquare)
	_, err = linalg.Cholesky(mat(t, []float64{1, 2}, []float64{3, 4}))
	wantErr(t, err, linalg.ErrNotSymmetric)
	_, err = linalg.Cholesky(mat(t, []float64{1, 2}, []float64{2, 1}))
	wantErr(t, err, linalg.ErrNotPositiveDefinite)
}
