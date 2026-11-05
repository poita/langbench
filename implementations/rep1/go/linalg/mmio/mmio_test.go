package mmio_test

import (
	"strings"
	"testing"

	"linalg"
	"linalg/mmio"
)

func parse(t *testing.T, s string) *linalg.Matrix {
	t.Helper()
	m, err := mmio.Parse([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func eq(t *testing.T, m *linalg.Matrix, rows, cols int, want ...float64) {
	t.Helper()
	if m.Rows != rows || m.Cols != cols {
		t.Fatalf("shape %dx%d", m.Rows, m.Cols)
	}
	for i, w := range want {
		if m.Data[i] != w {
			t.Fatalf("row-major data %v, want %v", m.Data, want)
		}
	}
}

func TestArrayGeneral(t *testing.T) {
	m := parse(t, "%%MatrixMarket matrix array real general\n% comment\n\n2 2\n1.0\n3.0\n\n2.0\n4.0\n")
	eq(t, m, 2, 2, 1, 2, 3, 4)
}

func TestArraySymmetricAndSkew(t *testing.T) {
	m := parse(t, "%%MatrixMarket matrix array real symmetric\n2 2\n4\n2\n5\n")
	eq(t, m, 2, 2, 4, 2, 2, 5)
	k := parse(t, "%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n")
	eq(t, k, 3, 3, 0, -1, -2, 1, 0, -3, 2, 3, 0)
}

func TestCoordinate(t *testing.T) {
	m := parse(t, "%%MatrixMarket MATRIX Coordinate Real General\n2 3 2\n2 1 5\n1 3 -1.5e0\n")
	eq(t, m, 2, 3, 0, 0, -1.5, 5, 0, 0)
	s := parse(t, "%%MatrixMarket matrix coordinate integer symmetric\n3 3 3\n1 1 2\n3 1 7\n2 2 1\n")
	eq(t, s, 3, 3, 2, 0, 7, 0, 1, 0, 7, 0, 0)
	p := parse(t, "%%MatrixMarket matrix coordinate pattern general\n2 2 2\n1 2\n2 1\n")
	eq(t, p, 2, 2, 0, 1, 1, 0)
	k := parse(t, "%%MatrixMarket matrix coordinate real skew-symmetric\n2 2 1\n2 1 3\n")
	eq(t, k, 2, 2, 0, -3, 3, 0)
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{
		"", "hello\n", "%%MatrixMarket matrix array real general\n",
		"%%MatrixMarket matrix array real general\n2 2\n1\n2\n",
		"%%MatrixMarket matrix coordinate real general\n2 2 1\n3 1 1\n",
		"%%MatrixMarket matrix array complex general\n1 1\n1\n",
	} {
		if _, err := mmio.Parse([]byte(s)); err == nil {
			t.Errorf("expected error for %q", s)
		}
	}
}

func TestFormat(t *testing.T) {
	m, _ := linalg.FromRows([][]float64{{1.5, -0.0}, {-7e-3, 40015.422479}})
	m.Data[1] = negZero()
	got := string(mmio.Format(m))
	want := "%%MatrixMarket matrix array real general\n2 2\n" +
		"1.5000000000e+00\n-7.0000000000e-03\n0.0000000000e+00\n4.0015422479e+04\n"
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if strings.Contains(got, "-0.0") {
		t.Error("negative zero printed")
	}
}

func negZero() float64 {
	z := 0.0
	return -z
}

func TestRoundTrip(t *testing.T) {
	m, _ := linalg.FromRows([][]float64{{1, 2.5, -3}, {4, 5, 6e10}})
	back := parse(t, string(mmio.Format(m)))
	eq(t, back, 2, 3, m.Data...)
}
