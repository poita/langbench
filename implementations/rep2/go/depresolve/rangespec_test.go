package depresolve

import "testing"

func TestRangeContains(t *testing.T) {
	cases := []struct {
		rng    string
		accept []string
		reject []string
	}{
		{"*", []string{"0.0.0", "999.9.9"}, nil},
		{"1.2.3", []string{"1.2.3"}, []string{"1.2.2", "1.2.4"}},
		{"^1.2.3", []string{"1.2.3", "1.9.0", "1.99.99"}, []string{"1.2.2", "2.0.0", "0.9.9"}},
		{"^0.2.3", []string{"0.2.3", "0.2.9"}, []string{"0.3.0", "0.2.2", "1.0.0"}},
		{"^0.0.3", []string{"0.0.3"}, []string{"0.0.2", "0.0.4", "0.1.0"}},
		{"^0.0.0", []string{"0.0.0"}, []string{"0.0.1"}},
		{"~1.2.3", []string{"1.2.3", "1.2.99"}, []string{"1.3.0", "1.2.2"}},
		{"~0.0.3", []string{"0.0.3", "0.0.9"}, []string{"0.1.0", "0.0.2"}},
		{">=1.0.0", []string{"1.0.0", "5.0.0"}, []string{"0.9.9"}},
		{">1.0.0", []string{"1.0.1", "2.0.0"}, []string{"1.0.0", "0.5.0"}},
		{"<2.0.0", []string{"1.99.99", "0.0.0"}, []string{"2.0.0"}},
		{"<=2.0.0", []string{"2.0.0", "1.0.0"}, []string{"2.0.1"}},
		{">=1.0.0 <2.0.0", []string{"1.0.0", "1.5.5"}, []string{"0.9.9", "2.0.0"}},
		{">1.0.0 <=1.0.2", []string{"1.0.1", "1.0.2"}, []string{"1.0.0", "1.0.3"}},
		{">=2.0.0 <1.0.0", nil, []string{"0.5.0", "1.5.0", "2.5.0"}},
		{">=1.0.0 >=1.5.0 <3.0.0", []string{"1.5.0", "2.9.9"}, []string{"1.4.9", "3.0.0"}},
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
		if r.String() != c.rng {
			t.Errorf("String() = %q, want %q", r.String(), c.rng)
		}
	}
}

func TestRangeEmpty(t *testing.T) {
	for rng, want := range map[string]bool{
		">=2.0.0 <1.0.0": true, ">1.0.0 <1.0.1": true, "<0.0.0": true,
		"*": false, "^1.0.0": false, "1.0.0": false, ">=1.0.0 <1.0.1": false,
	} {
		if got := MustParseRange(t, rng).Empty(); got != want {
			t.Errorf("Empty(%q) = %v, want %v", rng, got, want)
		}
	}
}

func MustParseRange(t *testing.T, s string) Range {
	t.Helper()
	r, err := ParseRange(s)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestParseRangeErrors(t *testing.T) {
	for _, in := range []string{"", "^", "~1.2", "=1.0.0", ">= 1.0.0", ">=1.0.0  <2.0.0", "^1.0", "x", ">1.0.0 foo"} {
		if _, err := ParseRange(in); err == nil {
			t.Errorf("ParseRange(%q) succeeded; want error", in)
		}
	}
}
