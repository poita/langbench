package numfmt

import (
	"math"
	"testing"
)

func TestFormatFloatAt(t *testing.T) {
	cases := []struct {
		x    float64
		d    int
		want string
	}{
		{1.0, 6, "1.000000"},
		{2.0 / 3.0, 6, "0.666667"},
		{math.Copysign(0, -1), 6, "-0.000000"},
		{2.5, 0, "2"},
		{3.5, 0, "4"},
		{0.5, 0, "0"},
		{sumPoint1Point2(), 17, "0.30000000000000004"},
		{1e21, 2, "1000000000000000000000.00"},
		{2.675, 2, "2.67"},
		{math.NaN(), 3, "nan"},
		{math.Inf(-1), 3, "-inf"},
		{math.Inf(1), 3, "inf"},
	}
	for _, c := range cases {
		if got := FormatFloatAt(c.x, c.d); got != c.want {
			t.Errorf("FormatFloatAt(%v, %d) = %q, want %q", c.x, c.d, got, c.want)
		}
	}
}

func TestIntRadix(t *testing.T) {
	if got := FormatIntRadix(math.MinInt64, 16); got != "-8000000000000000" {
		t.Errorf("got %q", got)
	}
	if got := FormatIntRadix(-255, 2); got != "-11111111" {
		t.Errorf("got %q", got)
	}
	v, ok := ParseIntRadix([]rune("-9223372036854775808"), 10)
	if !ok || v != math.MinInt64 {
		t.Errorf("min parse: %v %v", v, ok)
	}
	if _, ok := ParseIntRadix([]rune("9223372036854775808"), 10); ok {
		t.Error("overflow accepted")
	}
	for _, bad := range []string{"", "+", "-", "1_0", " 1", "1 "} {
		if _, ok := ParseIntRadix([]rune(bad), 10); ok {
			t.Errorf("%q accepted", bad)
		}
	}
	if v, ok := ParseIntRadix([]rune("-Zz"), 36); !ok || v != -1295 {
		t.Errorf("radix 36: %v %v", v, ok)
	}
}

func TestParseFloat(t *testing.T) {
	good := map[string]float64{"12": 12, "12.": 12, ".5": 0.5, "-.5": -0.5, "+1.5E-2": 0.015, "1e5": 1e5}
	for s, want := range good {
		got, ok := ParseFloat([]rune(s))
		if !ok || got != want {
			t.Errorf("ParseFloat(%q) = %v, %v", s, got, ok)
		}
	}
	for _, s := range []string{"", ".", "e5", "1e", "1e+", "1_0", " 1", "inf", "nan", "0x10"} {
		if _, ok := ParseFloat([]rune(s)); ok {
			t.Errorf("%q accepted", s)
		}
	}
	if f, ok := ParseFloat([]rune("1e400")); !ok || !math.IsInf(f, 1) {
		t.Errorf("overflow: %v %v", f, ok)
	}
}

// sumPoint1Point2 adds at run time: a constant expression would be exact.
func sumPoint1Point2() float64 {
	a, b := 0.1, 0.2
	return a + b
}
