package depresolve

import "testing"

func TestParseVersion(t *testing.T) {
	good := map[string]Version{
		"0.0.0":             {0, 0, 0},
		"1.10.0":            {1, 10, 0},
		"1000000.1000000.1": {1000000, 1000000, 1},
	}
	for s, want := range good {
		got, err := ParseVersion(s)
		if err != nil || got != want {
			t.Errorf("ParseVersion(%q) = %v, %v; want %v", s, got, err, want)
		}
		if got.String() != s {
			t.Errorf("String() = %q; want %q", got.String(), s)
		}
	}
	for _, s := range []string{"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "a.b.c",
		"1.2.-3", "1..3", "1.2.3 ", "1000001.0.0", "99999999.0.0", "+1.2.3"} {
		if _, err := ParseVersion(s); err == nil {
			t.Errorf("ParseVersion(%q) succeeded; want error", s)
		}
	}
}

func TestVersionOrder(t *testing.T) {
	order := []Version{{0, 0, 0}, {0, 0, 1}, {0, 1, 0}, {0, 9, 9}, {1, 0, 0}, {1, 9, 0},
		{1, 10, 0}, {2, 0, 0}, {1000000, 1000000, 1000000}}
	for i, a := range order {
		for j, b := range order {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := a.Compare(b); got != want {
				t.Errorf("%v.Compare(%v) = %d; want %d", a, b, got, want)
			}
			if a.Less(b) != (i < j) {
				t.Errorf("%v.Less(%v) wrong", a, b)
			}
		}
	}
}

func TestKeyRoundTrip(t *testing.T) {
	for _, v := range []Version{{0, 0, 0}, {1, 2, 3}, {1000000, 1000000, 1000000}} {
		if got := versionFromKey(v.key()); got != v {
			t.Errorf("round trip of %v gave %v", v, got)
		}
	}
}
