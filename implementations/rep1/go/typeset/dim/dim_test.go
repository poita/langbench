package dim

import "testing"

func TestFloorDiv(t *testing.T) {
	cases := []struct{ a, b, want int64 }{
		{7, 2, 3}, {-7, 2, -4}, {-3307000, 5100, -649}, {0, 5, 0}, {-1, 1000, -1}, {-1000, 1000, -1},
	}
	for _, c := range cases {
		if got := FloorDiv(c.a, c.b); got != c.want {
			t.Errorf("FloorDiv(%d,%d) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestScale(t *testing.T) {
	if got := Scale(1563, 10000); got != 15630 {
		t.Errorf("Scale = %d", got)
	}
	if got := Scale(-60, 10001); got != -601 {
		t.Errorf("negative Scale = %d, want -601", got)
	}
}

func TestParseLength(t *testing.T) {
	good := map[string]int64{
		"2.5pt": 2500, "0.5pt": 500, "1.5mm": 4252, "-6pt": -6000, "734": 734,
		"1in": 72000, "1pc": 12000, "1cm": 28350, "0": 0, "-1.5mm": -4252,
	}
	for s, want := range good {
		got, ok := ParseLength(s)
		if !ok || got != want {
			t.Errorf("ParseLength(%q) = %d,%v want %d", s, got, ok, want)
		}
	}
	for _, s := range []string{"", "+1pt", "1.2345pt", ".5pt", "1.pt", "1px", "1 pt", "pt", "-", "1..5"} {
		if _, ok := ParseLength(s); ok {
			t.Errorf("ParseLength(%q) accepted", s)
		}
	}
}

func TestParseInteger(t *testing.T) {
	if v, ok := ParseInteger("-12"); !ok || v != -12 {
		t.Error("-12")
	}
	for _, s := range []string{"", "+1", "1.0", "a", "-"} {
		if _, ok := ParseInteger(s); ok {
			t.Errorf("ParseInteger(%q) accepted", s)
		}
	}
}
