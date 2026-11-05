package depresolve

import "testing"

func mustV(t *testing.T, s string) Version {
	t.Helper()
	v, err := ParseVersion(s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestRangeSemantics(t *testing.T) {
	tests := []struct {
		rng    string
		accept []string
		reject []string
	}{
		{"*", []string{"0.0.0", "1.2.3", "1000000.1000000.1000000"}, nil},
		{"1.2.3", []string{"1.2.3"}, []string{"1.2.2", "1.2.4", "1.3.3"}},
		{"^1.2.3", []string{"1.2.3", "1.2.4", "1.9.0", "1.10.0"}, []string{"1.2.2", "2.0.0", "0.9.9"}},
		{"^0.2.3", []string{"0.2.3", "0.2.99"}, []string{"0.2.2", "0.3.0", "1.0.0"}},
		{"^0.0.3", []string{"0.0.3"}, []string{"0.0.2", "0.0.4", "0.1.0"}},
		{"^0.0.0", []string{"0.0.0"}, []string{"0.0.1"}},
		{"~1.2.3", []string{"1.2.3", "1.2.9"}, []string{"1.2.2", "1.3.0", "2.2.3"}},
		{"~0.0.3", []string{"0.0.3", "0.0.4", "0.0.99"}, []string{"0.0.2", "0.1.0"}},
		{"~0.2.0", []string{"0.2.0", "0.2.5"}, []string{"0.3.0"}},
		{"<1.0.0", []string{"0.9.9", "0.0.0"}, []string{"1.0.0", "1.0.1"}},
		{"<=1.0.0", []string{"1.0.0", "0.5.0"}, []string{"1.0.1"}},
		{">1.0.0", []string{"1.0.1", "2.0.0"}, []string{"1.0.0", "0.9.9"}},
		{">=1.0.0", []string{"1.0.0", "2.0.0"}, []string{"0.9.9"}},
		{">=1.2.0 <2.0.0", []string{"1.2.0", "1.9.9"}, []string{"1.1.9", "2.0.0"}},
		{">1.0.0 <=1.5.0 >=1.2.0", []string{"1.2.0", "1.5.0"}, []string{"1.1.9", "1.5.1", "1.0.0"}},
		{">=2.0.0 <1.0.0", nil, []string{"0.5.0", "1.5.0", "2.5.0"}},
		{">=1000000.1000000.1000000", []string{"1000000.1000000.1000000"}, []string{"1.0.0"}},
		{"<=1000000.1000000.1000000", []string{"1000000.1000000.1000000"}, nil},
		{"^1000000.0.0", []string{"1000000.5.5"}, []string{"999999.0.0"}},
	}
	for _, tc := range tests {
		r, err := ParseRange(tc.rng)
		if err != nil {
			t.Errorf("ParseRange(%q): %v", tc.rng, err)
			continue
		}
		for _, s := range tc.accept {
			if !r.Contains(mustV(t, s)) {
				t.Errorf("%q should accept %s", tc.rng, s)
			}
		}
		for _, s := range tc.reject {
			if r.Contains(mustV(t, s)) {
				t.Errorf("%q should reject %s", tc.rng, s)
			}
		}
	}
}

func TestRangeEmpty(t *testing.T) {
	for s, want := range map[string]bool{
		">=2.0.0 <1.0.0": true, ">1.0.0 <1.0.1": true, "<0.0.0": true,
		"*": false, "1.0.0": false, "^0.0.1": false, ">=1.0.0 <1.0.1": false,
	} {
		r, err := ParseRange(s)
		if err != nil {
			t.Fatal(err)
		}
		if r.Empty() != want {
			t.Errorf("%q.Empty() = %v; want %v", s, r.Empty(), want)
		}
	}
	if !(Range{}).Empty() {
		t.Error("zero Range should be empty")
	}
}

func TestParseRangeErrors(t *testing.T) {
	for _, s := range []string{"", "^", "~1.2", "^1.2", "=1.0.0", ">=1.0.0<2.0.0", ">= 1.0.0",
		">1.0.0 >2.0.0 >3.0.0 >4.0.0", "x", "1.0", ">1.0.0  <2.0.0", "^ 1.0.0", "*  ", "<"} {
		if _, err := ParseRange(s); err == nil {
			t.Errorf("ParseRange(%q) succeeded; want error", s)
		}
	}
	if _, err := ParseRange(">0.0.0 <9.0.0 <8.0.0"); err != nil {
		t.Errorf("three comparators should be accepted: %v", err)
	}
}

func TestConstructors(t *testing.T) {
	v := Version{1, 2, 3}
	if !Exact(v).Contains(v) || Exact(v).Contains(Version{1, 2, 4}) {
		t.Error("Exact")
	}
	if !Caret(v).Contains(Version{1, 9, 0}) || Caret(v).Contains(Version{2, 0, 0}) {
		t.Error("Caret")
	}
	if !Tilde(v).Contains(Version{1, 2, 9}) || Tilde(v).Contains(Version{1, 3, 0}) {
		t.Error("Tilde")
	}
	if !AnyVersion.Contains(Version{}) {
		t.Error("AnyVersion")
	}
}
