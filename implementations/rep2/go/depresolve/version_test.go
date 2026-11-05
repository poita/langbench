package depresolve

import "testing"

func TestParseVersion(t *testing.T) {
	good := map[string]Version{
		"0.0.0":             {0, 0, 0},
		"1.2.3":             {1, 2, 3},
		"1.10.0":            {1, 10, 0},
		"1000000.1000000.0": {1000000, 1000000, 0},
	}
	for s, want := range good {
		got, err := ParseVersion(s)
		if err != nil || got != want {
			t.Errorf("ParseVersion(%q) = %v, %v; want %v", s, got, err, want)
		}
		if got.String() != s {
			t.Errorf("String() = %q, want %q", got.String(), s)
		}
	}
	for _, s := range []string{"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.-3", "a.b.c", "1..3", "1.2.1000001", " 1.2.3", "1.2.3-beta"} {
		if v, err := ParseVersion(s); err == nil {
			t.Errorf("ParseVersion(%q) = %v, want error", s, v)
		}
	}
}

func TestVersionCompareIsNumeric(t *testing.T) {
	ordered := []string{"0.0.0", "0.0.1", "0.1.0", "0.9.9", "1.0.0", "1.9.0", "1.10.0", "2.0.0", "10.0.0", "1000000.1000000.1000000"}
	for i, a := range ordered {
		for j, b := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := MustParseVersion(a).Compare(MustParseVersion(b)); got != want {
				t.Errorf("Compare(%s, %s) = %d, want %d", a, b, got, want)
			}
		}
	}
}

func TestMustParseVersionPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("expected panic")
		}
	}()
	MustParseVersion("nope")
}
