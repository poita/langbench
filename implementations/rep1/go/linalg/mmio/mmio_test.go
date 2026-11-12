package mmio

import (
	"bytes"
	"strings"
	"testing"

	"example.com/linalg"
)

func equal(a *linalg.Matrix, rows [][]float64) bool {
	b := linalg.FromRows(rows)
	if a.Rows != b.Rows || a.Cols != b.Cols {
		return false
	}
	for i := range a.Data {
		if a.Data[i] != b.Data[i] {
			return false
		}
	}
	return true
}

func TestParse(t *testing.T) {
	tests := []struct {
		name, text string
		want       [][]float64
	}{
		{"array general", "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n",
			[][]float64{{1, 2}, {3, 4}}},
		{"array symmetric", "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n",
			[][]float64{{4, 2}, {2, 5}}},
		{"array skew", "%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n",
			[][]float64{{0, -1, -2}, {1, 0, -3}, {2, 3, 0}}},
		{"coordinate general", "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n",
			[][]float64{{0.5, 0}, {0, -1.5}}},
		{"coordinate symmetric", "%%MatrixMarket matrix coordinate real symmetric\n% c\n\n3 3 2\n2 1 7\n3 3 1e0\n",
			[][]float64{{0, 7, 0}, {7, 0, 0}, {0, 0, 1}}},
		{"coordinate skew", "%%MatrixMarket matrix coordinate integer skew-symmetric\n2 2 1\n2 1 5\n",
			[][]float64{{0, -5}, {5, 0}}},
		{"pattern, case-insensitive", "%%MatrixMarket MATRIX Coordinate Pattern General\n2 3 2\n1 3\n2 1\n",
			[][]float64{{0, 0, 1}, {1, 0, 0}}},
		{"blank lines and spaces", "%%MatrixMarket matrix array real general\n\n1 2\n  \n 1.5E+00 \n\t-2\n",
			[][]float64{{1.5, -2}}},
	}
	for _, tc := range tests {
		m, err := Parse(tc.text)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if !equal(m, tc.want) {
			t.Errorf("%s: got %v", tc.name, m.Data)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, text := range []string{
		"", "not a banner\n1 1\n1\n",
		"%%MatrixMarket matrix array complex general\n1 1\n1 0\n",
		"%%MatrixMarket matrix array real general\n2 2\n1\n2\n",
	} {
		if _, err := Parse(text); err == nil {
			t.Errorf("expected error for %q", text)
		}
	}
}

func TestFormatValue(t *testing.T) {
	negZero := 0.0
	negZero = -negZero
	for _, tc := range []struct {
		v    float64
		want string
	}{
		{1.2345678901234, "1.2345678901e+00"},
		{-0.007, "-7.0000000000e-03"},
		{40015.422479, "4.0015422479e+04"},
		{0, "0.0000000000e+00"},
		{negZero, "0.0000000000e+00"},
		{1e100, "1.0000000000e+100"},
		{-2.5e-7, "-2.5000000000e-07"},
	} {
		if got := FormatValue(tc.v); got != tc.want {
			t.Errorf("FormatValue(%g) = %q, want %q", tc.v, got, tc.want)
		}
	}
}

func TestWrite(t *testing.T) {
	m := linalg.FromRows([][]float64{{1, 2}, {3, 4}})
	var buf bytes.Buffer
	if err := Write(&buf, m); err != nil {
		t.Fatal(err)
	}
	want := "%%MatrixMarket matrix array real general\n2 2\n" +
		"1.0000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n4.0000000000e+00\n"
	if buf.String() != want {
		t.Errorf("got %q", buf.String())
	}
	back, err := Read(strings.NewReader(buf.String()))
	if err != nil || !equal(back, [][]float64{{1, 2}, {3, 4}}) {
		t.Errorf("round trip: %v %v", back, err)
	}
}
