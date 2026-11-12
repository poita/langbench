package depresolve

import "testing"

func TestParseVersion(t *testing.T) {
	good := map[string]Version{
		"0.0.0":             {0, 0, 0},
		"1.10.0":            {1, 10, 0},
		"1000000.0.1000000": {1000000, 0, 1000000},
	}
	for in, want := range good {
		got, err := ParseVersion(in)
		if err != nil || got != want {
			t.Errorf("ParseVersion(%q) = %v, %v; want %v", in, got, err, want)
		}
		if got.String() != in {
			t.Errorf("String round trip of %q gave %q", in, got.String())
		}
	}
	for _, in := range []string{"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.x", "-1.0.0", "1..3", "99999999999.0.0", "1.2.3-rc"} {
		if _, err := ParseVersion(in); err == nil {
			t.Errorf("ParseVersion(%q) succeeded; want error", in)
		}
	}
}

func TestVersionCompareNumeric(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.10.0", "1.9.0", 1},
		{"1.9.0", "1.10.0", -1},
		{"2.0.0", "1.99.99", 1},
		{"0.0.1", "0.0.1", 0},
		{"1.2.3", "1.2.10", -1},
	}
	for _, c := range cases {
		if got := MustParseVersion(c.a).Compare(MustParseVersion(c.b)); got != c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}
