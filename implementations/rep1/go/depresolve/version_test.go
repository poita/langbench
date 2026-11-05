package depresolve

import "testing"

func TestParseVersion(t *testing.T) {
	v, err := ParseVersion("1.10.0")
	if err != nil || v != (Version{1, 10, 0}) {
		t.Fatalf("got %v, %v", v, err)
	}
	for _, bad := range []string{"", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1..3", "1.2.1000000000", "-1.0.0"} {
		if _, err := ParseVersion(bad); err == nil {
			t.Errorf("ParseVersion(%q) succeeded", bad)
		}
	}
	if _, err := ParseVersion("1000000.1000000.1000000"); err != nil {
		t.Errorf("max components rejected: %v", err)
	}
}

func TestVersionOrderAndKey(t *testing.T) {
	a, b := Version{1, 9, 0}, Version{1, 10, 0}
	if a.Compare(b) != -1 || b.Compare(a) != 1 || a.Compare(a) != 0 {
		t.Error("Compare wrong")
	}
	if a.Key() >= b.Key() {
		t.Error("Key does not order numerically")
	}
	if got := VersionFromKey(b.Key()); got != b {
		t.Errorf("round trip: %v", got)
	}
	if b.String() != "1.10.0" {
		t.Errorf("String = %q", b.String())
	}
}
