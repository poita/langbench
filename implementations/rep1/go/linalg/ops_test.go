package linalg_test

import (
	"testing"

	"linalg"
)

func TestAddMulTranspose(t *testing.T) {
	a := mat(t, []float64{1, 2, 3}, []float64{4, 5, 6})
	b := mat(t, []float64{1, 0}, []float64{0, 1}, []float64{2, 2})
	sum, err := linalg.Add(a, a)
	if err != nil {
		t.Fatal(err)
	}
	near(t, sum, mat(t, []float64{2, 4, 6}, []float64{8, 10, 12}), 0)
	near(t, mustMul(t, a, b), mat(t, []float64{7, 8}, []float64{16, 17}), 0)
	near(t, linalg.Transpose(a), mat(t, []float64{1, 4}, []float64{2, 5}, []float64{3, 6}), 0)
}

func TestOpErrors(t *testing.T) {
	a := linalg.New(2, 3)
	_, err := linalg.Add(a, linalg.New(3, 2))
	wantErr(t, err, linalg.ErrDimensionMismatch)
	_, err = linalg.Mul(a, a)
	wantErr(t, err, linalg.ErrDimensionMismatch)
}

func TestNorms(t *testing.T) {
	a := mat(t, []float64{1, -2}, []float64{-3, 4})
	if got := linalg.Norm1(a); got != 6 {
		t.Errorf("Norm1 = %v", got)
	}
	if got := linalg.NormInf(a); got != 7 {
		t.Errorf("NormInf = %v", got)
	}
	if got := linalg.NormFro(a); got*got < 29.999999 || got*got > 30.000001 {
		t.Errorf("NormFro = %v", got)
	}
}

func TestMatrixHelpers(t *testing.T) {
	if _, err := linalg.FromRows([][]float64{{1}, {1, 2}}); err == nil {
		t.Error("ragged rows accepted")
	}
	s := mat(t, []float64{1, 2}, []float64{2, 1})
	if !s.IsSymmetric() {
		t.Error("symmetric matrix not detected")
	}
	s.Set(0, 1, 3)
	if s.IsSymmetric() || s.At(0, 1) != 3 {
		t.Error("asymmetry not detected")
	}
	c := s.Clone()
	c.Set(0, 0, 9)
	if s.At(0, 0) == 9 {
		t.Error("Clone aliases data")
	}
}
