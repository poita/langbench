package jsonvalue

import "testing"

func mustNum(t *testing.T, s string) Number {
	t.Helper()
	n, err := ParseNumber(s)
	if err != nil {
		t.Fatalf("ParseNumber(%q): %v", s, err)
	}
	return n
}

func TestParseNumberRejectsBadLiterals(t *testing.T) {
	for _, s := range []string{"", "-", "01", "1.", ".5", "1e", "1e+", "+1", "1.5.2", "0x10", "--1", "1 "} {
		if _, err := ParseNumber(s); err == nil {
			t.Errorf("ParseNumber(%q) succeeded, want error", s)
		}
	}
}

func TestNumbersWithSameValueAreEqual(t *testing.T) {
	groups := [][]string{
		{"1", "1.0", "1.00", "1e0", "10e-1", "0.1e1"},
		{"100", "1e2", "1.0e2", "100.0", "10000e-2"},
		{"0", "-0", "0.0", "0e5", "-0.000"},
		{"-1.5", "-15e-1", "-0.15e1"},
	}
	for _, g := range groups {
		first := mustNum(t, g[0])
		for _, s := range g[1:] {
			n := mustNum(t, s)
			if !first.Equal(n) || first.Cmp(n) != 0 {
				t.Errorf("%s and %s should be equal", g[0], s)
			}
		}
	}
	if mustNum(t, "1").Equal(mustNum(t, "-1")) {
		t.Error("1 equals -1")
	}
}

func TestCmpIsExact(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"1", "2", -1},
		{"2", "1", 1},
		{"-2", "-1", -1},
		{"-1", "1", -1},
		{"0", "-1", 1},
		{"1e308", "1e309", -1},
		{"1e400", "1e399", 1},
		{"0.1", "0.10000000000000001", -1},
		{"12345678901234567890123", "12345678901234567890124", -1},
		{"12345678901234567890123", "1.2345678901234567890123e22", 0},
		{"9007199254740993", "9007199254740992", 1},
		{"1e-400", "0", 1},
		{"-1e-400", "0", -1},
		{"0.30000000000000004", "0.3", 1},
	}
	for _, tc := range tests {
		got := mustNum(t, tc.a).Cmp(mustNum(t, tc.b))
		if got != tc.want {
			t.Errorf("Cmp(%s, %s) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestIsInteger(t *testing.T) {
	yes := []string{"0", "-0", "1", "1.0", "1e2", "100e-2", "-5", "1e400", "12345678901234567890123"}
	no := []string{"1.5", "0.1", "1e-1", "-0.5", "1e-400"}
	for _, s := range yes {
		if !mustNum(t, s).IsInteger() {
			t.Errorf("%s should be an integer", s)
		}
	}
	for _, s := range no {
		if mustNum(t, s).IsInteger() {
			t.Errorf("%s should not be an integer", s)
		}
	}
}

func TestMultipleOf(t *testing.T) {
	tests := []struct {
		x, d string
		want bool
	}{
		{"10", "5", true},
		{"10", "3", false},
		{"0.3", "0.0001", true},
		{"0.0021", "0.0001", true},
		{"0.00751", "0.0001", false},
		{"4.5", "1.5", true},
		{"4.5", "0.5", true},
		{"0", "7", true},
		{"-6", "3", true},
		{"1e308", "0.5", true},
		{"1e-400", "1e-400", true},
		{"3e-400", "2e-400", false},
		{"12345678901234567890123456", "2", true},
		{"12345678901234567890123457", "2", false},
		{"1", "1e-400", true},
		{"1e400", "3", false},
		{"0.1", "1", false},
		{"7.5", "2.5", true},
	}
	for _, tc := range tests {
		if got := mustNum(t, tc.x).MultipleOf(mustNum(t, tc.d)); got != tc.want {
			t.Errorf("%s multipleOf %s = %v, want %v", tc.x, tc.d, got, tc.want)
		}
	}
}

func TestInt64Saturates(t *testing.T) {
	tests := []struct {
		s    string
		want int64
	}{
		{"0", 0}, {"7", 7}, {"2.0", 2}, {"2e0", 2}, {"1e2", 100}, {"-3", -3},
		{"2.9", 2}, {"-2.9", -2}, {"0.5", 0},
		{"9223372036854775807", 9223372036854775807},
		{"9223372036854775808", 9223372036854775807},
		{"1e400", 9223372036854775807},
		{"-1e400", -9223372036854775808},
		{"1e-400", 0},
	}
	for _, tc := range tests {
		if got := mustNum(t, tc.s).Int64(); got != tc.want {
			t.Errorf("Int64(%s) = %d, want %d", tc.s, got, tc.want)
		}
	}
}

func TestNumberFromInt64AndString(t *testing.T) {
	if got := NumberFromInt64(-120).String(); got != "-12e1" {
		t.Errorf("String() = %q", got)
	}
	if !NumberFromInt64(0).IsZero() {
		t.Error("0 is not zero")
	}
	if !NumberFromInt64(-9223372036854775808).Equal(mustNum(t, "-9223372036854775808")) {
		t.Error("min int64 mismatch")
	}
}
