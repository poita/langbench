package linalg_test

import (
	"math"
	"testing"

	"linalg"
)

func TestEigSymSmall(t *testing.T) {
	e, err := linalg.EigSym(mat(t, []float64{2, 1}, []float64{1, 3}))
	if err != nil {
		t.Fatal(err)
	}
	r5 := math.Sqrt(5)
	if math.Abs(e.Values[0]-(5-r5)/2) > 1e-14 || math.Abs(e.Values[1]-(5+r5)/2) > 1e-14 {
		t.Errorf("values = %v", e.Values)
	}
	near(t, e.Vectors, mat(t, []float64{0.8506508083520399, 0.5257311121191336},
		[]float64{-0.5257311121191336, 0.8506508083520399}), 1e-12)
}

func TestEigSymRandom(t *testing.T) {
	g := randMat(6, 25, 25)
	a, _ := linalg.Add(g, linalg.Transpose(g))
	e, err := linalg.EigSym(a)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i < 25; i++ {
		if e.Values[i] < e.Values[i-1] {
			t.Fatal("eigenvalues not ascending")
		}
	}
	d := linalg.New(25, 25)
	for i, w := range e.Values {
		d.Set(i, i, w)
	}
	near(t, mustMul(t, a, e.Vectors), mustMul(t, e.Vectors, d), 1e-12)
	near(t, mustMul(t, linalg.Transpose(e.Vectors), e.Vectors), linalg.Identity(25), 1e-12)
}

func TestEigSymDiagonalAndErrors(t *testing.T) {
	e, err := linalg.EigSym(mat(t, []float64{3, 0}, []float64{0, 1}))
	if err != nil {
		t.Fatal(err)
	}
	if e.Values[0] != 1 || e.Values[1] != 3 {
		t.Errorf("values = %v", e.Values)
	}
	_, err = linalg.EigSym(linalg.New(2, 3))
	wantErr(t, err, linalg.ErrNotSquare)
	_, err = linalg.EigSym(mat(t, []float64{1, 2}, []float64{3, 4}))
	wantErr(t, err, linalg.ErrNotSymmetric)
}

func TestSignNormalize(t *testing.T) {
	m := mat(t, []float64{1, 0}, []float64{-3, 0})
	if !linalg.SignNormalize(m, 0) || m.At(0, 0) != -1 || m.At(1, 0) != 3 {
		t.Errorf("column not negated: %v", m.Data)
	}
	if linalg.SignNormalize(m, 1) {
		t.Error("zero column negated")
	}
	tie := mat(t, []float64{-2}, []float64{2})
	if !linalg.SignNormalize(tie, 0) {
		t.Error("tie should pick the first (negative) entry")
	}
}
