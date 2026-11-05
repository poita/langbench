package cellref

import "testing"

func TestParse(t *testing.T) {
	good := map[string][2]int{"A1": {1, 1}, "Z9": {26, 9}, "AA10": {27, 10}, "ZZ9999": {702, 9999}, "AB123": {28, 123}}
	for s, want := range good {
		c, r, ok := Parse(s)
		if !ok || c != want[0] || r != want[1] {
			t.Errorf("Parse(%q) = %d,%d,%v; want %v", s, c, r, ok, want)
		}
	}
	for _, s := range []string{"", "A", "1", "AAA1", "A0", "A01", "A10000", "a1", "A1x", "A-1", "1A"} {
		if _, _, ok := Parse(s); ok {
			t.Errorf("Parse(%q) accepted", s)
		}
	}
}

func TestKeyOrderAndRoundTrip(t *testing.T) {
	if !(Key(702, 1) < Key(1, 2)) || !(Key(1, 1) < Key(2, 1)) {
		t.Error("keys are not row-major")
	}
	for _, name := range []string{"A1", "Z26", "AA1", "AZ5", "BA7", "ZZ9999"} {
		c, r, _ := Parse(name)
		if got := Name(c, r); got != name {
			t.Errorf("Name round trip: %q -> %q", name, got)
		}
		c2, r2 := Split(Key(c, r))
		if c2 != c || r2 != r {
			t.Errorf("Split(Key) mismatch for %q", name)
		}
	}
}
