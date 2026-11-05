package depresolve

import "testing"

func TestRangeSemantics(t *testing.T) {
	tests := []struct {
		rng    string
		accept []string
		reject []string
	}{
		{"*", []string{"0.0.0", "1000000.1000000.1000000"}, nil},
		{"1.2.3", []string{"1.2.3"}, []string{"1.2.4", "1.2.2"}},
		{"^1.2.3", []string{"1.2.3", "1.9.0", "1.999.9"}, []string{"1.2.2", "2.0.0"}},
		{"^0.2.3", []string{"0.2.3", "0.2.9"}, []string{"0.3.0", "0.2.2", "1.0.0"}},
		{"^0.0.3", []string{"0.0.3"}, []string{"0.0.4", "0.0.2", "0.1.0"}},
		{"^0.0.0", []string{"0.0.0"}, []string{"0.0.1"}},
		{"~1.2.3", []string{"1.2.3", "1.2.99"}, []string{"1.3.0", "1.2.2"}},
		{"~0.0.3", []string{"0.0.3", "0.0.9"}, []string{"0.1.0", "0.0.2"}},
		{">=1.0.0 <2.0.0", []string{"1.0.0", "1.99.0"}, []string{"0.9.9", "2.0.0"}},
		{">1.0.0", []string{"1.0.1", "2.0.0"}, []string{"1.0.0"}},
		{"<=1.0.0", []string{"1.0.0", "0.5.0"}, []string{"1.0.1"}},
		{"<1.0.0", []string{"0.9.9"}, []string{"1.0.0"}},
		{">=1.0.0 <=3.0.0 >1.5.0", []string{"1.5.1", "3.0.0"}, []string{"1.5.0", "3.0.1"}},
		{">=2.0.0 <1.0.0", nil, []string{"0.0.0", "1.5.0", "2.0.0"}},
		{"^1000000.0.0", []string{"1000000.5.5"}, nil},
		{"<=1000000.1000000.1000000", []string{"1000000.1000000.1000000"}, nil},
	}
	for _, tc := range tests {
		r, err := ParseRange(tc.rng)
		if err != nil {
			t.Errorf("ParseRange(%q): %v", tc.rng, err)
			continue
		}
		for _, s := range tc.accept {
			v, _ := ParseVersion(s)
			if !r.Contains(v) {
				t.Errorf("%q should accept %s", tc.rng, s)
			}
		}
		for _, s := range tc.reject {
			v, _ := ParseVersion(s)
			if r.Contains(v) {
				t.Errorf("%q should reject %s", tc.rng, s)
			}
		}
	}
}

func TestRangeEmpty(t *testing.T) {
	r, _ := ParseRange(">=2.0.0 <1.0.0")
	if !r.Empty() {
		t.Error("expected empty")
	}
	if AnyVersion.Empty() {
		t.Error("* must not be empty")
	}
}

func TestParseRangeErrors(t *testing.T) {
	for _, bad := range []string{"", "**", "^", "~1.2", ">=", ">=1.0.0<2.0.0", "=1.0.0", "^1.0", ">>1.0.0", "1.0.0 2.0.0"} {
		if _, err := ParseRange(bad); err == nil {
			t.Errorf("ParseRange(%q) succeeded", bad)
		}
	}
}
