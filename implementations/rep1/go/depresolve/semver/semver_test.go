package semver

import "testing"

func TestParseVersion(t *testing.T) {
	good := map[string]Version{
		"0.0.0":            {0, 0, 0},
		"1.10.0":           {1, 10, 0},
		"1000000.0.999999": {1000000, 0, 999999},
	}
	for in, want := range good {
		got, err := ParseVersion(in)
		if err != nil || got != want {
			t.Errorf("ParseVersion(%q) = %v, %v; want %v", in, got, err, want)
		}
		if got.String() != in {
			t.Errorf("String() = %q, want %q", got.String(), in)
		}
	}
	for _, in := range []string{"", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1..3", "-1.0.0", "1.2.3-rc1", "99999999999.0.0"} {
		if _, err := ParseVersion(in); err == nil {
			t.Errorf("ParseVersion(%q) succeeded, want error", in)
		}
	}
}

func TestCompareNumeric(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.10.0", "1.9.0", 1},
		{"1.9.0", "1.10.0", -1},
		{"2.0.0", "1.99.99", 1},
		{"1.2.3", "1.2.3", 0},
		{"0.0.1", "0.0.2", -1},
	}
	for _, c := range cases {
		if got := MustParseVersion(c.a).Compare(MustParseVersion(c.b)); got != c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestRangeSemantics(t *testing.T) {
	cases := []struct {
		rng    string
		accept []string
		reject []string
	}{
		{"*", []string{"0.0.0", "99.9.9"}, nil},
		{"1.2.3", []string{"1.2.3"}, []string{"1.2.2", "1.2.4"}},
		{"^1.2.3", []string{"1.2.3", "1.9.0"}, []string{"1.2.2", "2.0.0"}},
		{"^0.2.3", []string{"0.2.3", "0.2.9"}, []string{"0.2.2", "0.3.0"}},
		{"^0.0.3", []string{"0.0.3"}, []string{"0.0.2", "0.0.4", "0.1.0"}},
		{"~1.2.3", []string{"1.2.3", "1.2.99"}, []string{"1.3.0", "1.2.2"}},
		{"~0.0.3", []string{"0.0.3", "0.0.9"}, []string{"0.1.0", "0.0.2"}},
		{"<1.0.0", []string{"0.9.9"}, []string{"1.0.0"}},
		{"<=1.0.0", []string{"1.0.0"}, []string{"1.0.1"}},
		{">1.0.0", []string{"1.0.1"}, []string{"1.0.0"}},
		{">=1.0.0", []string{"1.0.0"}, []string{"0.9.9"}},
		{">=1.2.0 <2.0.0", []string{"1.2.0", "1.99.0"}, []string{"1.1.9", "2.0.0"}},
		{">1.0.0 <=1.0.2 >=1.0.2", []string{"1.0.2"}, []string{"1.0.1", "1.0.3"}},
		{">=2.0.0 <1.0.0", nil, []string{"0.5.0", "1.5.0", "2.5.0"}},
	}
	for _, c := range cases {
		r, err := ParseRange(c.rng)
		if err != nil {
			t.Errorf("ParseRange(%q): %v", c.rng, err)
			continue
		}
		for _, v := range c.accept {
			if !r.Contains(MustParseVersion(v)) {
				t.Errorf("%q should accept %s", c.rng, v)
			}
		}
		for _, v := range c.reject {
			if r.Contains(MustParseVersion(v)) {
				t.Errorf("%q should reject %s", c.rng, v)
			}
		}
	}
}

func TestRangeEmpty(t *testing.T) {
	for rng, want := range map[string]bool{
		">=2.0.0 <1.0.0": true,
		"<0.0.0":         true,
		">1.0.0 <1.0.1":  true,
		"*":              false,
		"^0.0.1":         false,
		">=1.0.0":        false,
	} {
		r, err := ParseRange(rng)
		if err != nil {
			t.Fatal(err)
		}
		if r.Empty() != want {
			t.Errorf("%q.Empty() = %v, want %v", rng, r.Empty(), want)
		}
	}
}

func TestParseRangeErrors(t *testing.T) {
	for _, in := range []string{"", "**", "^", "~1.2", "=1.0.0", "<", ">=1.0", "<1.0.0 1.0.0", "1.0.0 <2.0.0"} {
		if _, err := ParseRange(in); err == nil {
			t.Errorf("ParseRange(%q) succeeded, want error", in)
		}
	}
}

func TestRangeString(t *testing.T) {
	for in, want := range map[string]string{
		"*":       "*",
		"^1.2.3":  ">=1.2.3 <2.0.0",
		">=1.0.0": ">=1.0.0",
		"<2.0.0":  "<2.0.0",
	} {
		if got := MustParseRange(in).String(); got != want {
			t.Errorf("String(%q) = %q, want %q", in, got, want)
		}
	}
}
