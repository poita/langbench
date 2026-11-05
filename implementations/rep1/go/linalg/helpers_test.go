package linalg_test

import (
	"math"
	"testing"

	"linalg"
)

func mat(t *testing.T, rows ...[]float64) *linalg.Matrix {
	t.Helper()
	m, err := linalg.FromRows(rows)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func near(t *testing.T, got, want *linalg.Matrix, tol float64) {
	t.Helper()
	if got.Rows != want.Rows || got.Cols != want.Cols {
		t.Fatalf("shape %dx%d, want %dx%d", got.Rows, got.Cols, want.Rows, want.Cols)
	}
	for i, v := range got.Data {
		if math.Abs(v-want.Data[i]) > tol {
			t.Fatalf("entry %d = %v, want %v\ngot  %v\nwant %v", i, v, want.Data[i], got.Data, want.Data)
		}
	}
}

func mustMul(t *testing.T, a, b *linalg.Matrix) *linalg.Matrix {
	t.Helper()
	c, err := linalg.Mul(a, b)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// lcg is a tiny deterministic generator for test matrices.
type lcg uint64

func (l *lcg) next() float64 {
	*l = *l*6364136223846793005 + 1442695040888963407
	return float64(*l>>11)/float64(1<<53)*2 - 1
}

func randMat(seed uint64, r, c int) *linalg.Matrix {
	g := lcg(seed)
	m := linalg.New(r, c)
	for i := range m.Data {
		m.Data[i] = g.next()
	}
	return m
}

func wantErr(t *testing.T, err, want error) {
	t.Helper()
	if err != want {
		t.Fatalf("error = %v, want %v", err, want)
	}
}
