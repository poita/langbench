package depresolve

import "testing"

func TestRangeContains(t *testing.T) {
	tests := []struct {
		rng    string
		yes    []string
		no     []string
		isNone bool
	}{
		{"*", []string{"0.0.0", "1.2.3", "1000000.0.0"}, nil, false},
		{"1.2.3", []string{"1.2.3"}, []string{"1.2.2", "1.2.4", "1.3.3"}, false},
		{"^1.2.3", []string{"1.2.3", "1.9.0", "1.999999.1"}, []string{"1.2.2", "2.0.0", "0.9.9"}, false},
		{"^0.2.3", []string{"0.2.3", "0.2.99"}, []string{"0.2.2", "0.3.0", "1.0.0"}, false},
		{"^0.0.3", []string{"0.0.3"}, []string{"0.0.2", "0.0.4", "0.1.0"}, false},
		{"^0.0.0", []string{"0.0.0"}, []string{"0.0.1"}, false},
		{"~1.2.3", []string{"1.2.3", "1.2.9"}, []string{"1.2.2", "1.3.0"}, false},
		{"~0.0.3", []string{"0.0.3", "0.0.9"}, []string{"0.0.2", "0.1.0"}, false},
		{"~1000000.1000000.0", []string{"1000000.1000000.5"}, []string{"1000000.999999.9"}, false},
		{"^1000000.0.0", []string{"1000000.5.5"}, []string{"999999.0.0"}, false},
		{"<2.0.0", []string{"0.0.0", "1.99.99"}, []string{"2.0.0", "3.0.0"}, false},
		{"<=2.0.0", []string{"2.0.0", "1.0.0"}, []string{"2.0.1"}, false},
		{">2.0.0", []string{"2.0.1", "3.0.0"}, []string{"2.0.0", "1.0.0"}, false},
		{">=2.0.0", []string{"2.0.0", "3.0.0"}, []string{"1.99.99"}, false},
		{">=1.0.0 <2.0.0", []string{"1.0.0", "1.5.0"}, []string{"0.9.9", "2.0.0"}, false},
		{">1.0.0 <=2.0.0 >=1.5.0", []string{"1.5.0", "2.0.0"}, []string{"1.0.0", "1.4.9", "2.0.1"}, false},
		{">=2.0.0 <1.0.0", nil, []string{"0.5.0", "1.5.0", "2.5.0"}, true},
		{">1000000.1000000.1000000", nil, []string{"1000000.1000000.1000000"}, false},
		{"<=1000000.1000000.1000000", []string{"1000000.1000000.1000000"}, nil, false},
	}
	for _, tc := range tests {
		r, err := ParseRange(tc.rng)
		if err != nil {
			t.Errorf("ParseRange(%q): %v", tc.rng, err)
			continue
		}
		if r.String() != tc.rng {
			t.Errorf("String() = %q, want %q", r.String(), tc.rng)
		}
		if r.Empty() != tc.isNone {
			t.Errorf("%q Empty() = %v", tc.rng, r.Empty())
		}
		for _, s := range tc.yes {
			if !r.Contains(MustParseVersion(s)) {
				t.Errorf("%q should accept %s", tc.rng, s)
			}
		}
		for _, s := range tc.no {
			if r.Contains(MustParseVersion(s)) {
				t.Errorf("%q should reject %s", tc.rng, s)
			}
		}
	}
}

func TestParseRangeErrors(t *testing.T) {
	for _, s := range []string{"", "^", "~1.2", "^1.2.3.4", ">=", ">= 1.0.0", "=1.0.0", ">=1.0.0  <2.0.0", "1.2", "x", "<<1.0.0"} {
		if r, err := ParseRange(s); err == nil {
			t.Errorf("ParseRange(%q) = %v, want error", s, r)
		}
	}
}

func TestZeroRangeIsEmpty(t *testing.T) {
	var r Range
	if !r.Empty() || r.Contains(Version{}) {
		t.Error("zero Range should be empty")
	}
	if !AnyRange().Contains(Version{1000000, 1000000, 1000000}) {
		t.Error("AnyRange should accept everything")
	}
}
