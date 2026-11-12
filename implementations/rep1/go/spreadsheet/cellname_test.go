package spreadsheet

import "testing"

func TestParseCellName(t *testing.T) {
	valid := []string{"A1", "Z9", "AA1", "ZZ9999", "AB123", "B2"}
	for _, n := range valid {
		k, ok := parseCellName(n)
		if !ok {
			t.Errorf("parseCellName(%q) rejected", n)
			continue
		}
		if k.String() != n {
			t.Errorf("round trip %q -> %q", n, k.String())
		}
	}
	invalid := []string{"", "A", "1", "AAA1", "A0", "A01", "A10000", "a1", "A1B", "A-1"}
	for _, n := range invalid {
		if _, ok := parseCellName(n); ok {
			t.Errorf("parseCellName(%q) accepted", n)
		}
	}
}

func TestKeyOrderIsRowMajor(t *testing.T) {
	order := []string{"A1", "B1", "Z1", "AA1", "ZZ1", "A2", "ZZ2", "A9999"}
	var prev cellKey
	for _, n := range order {
		k, _ := parseCellName(n)
		if k <= prev {
			t.Errorf("%s not after previous key", n)
		}
		prev = k
	}
}
