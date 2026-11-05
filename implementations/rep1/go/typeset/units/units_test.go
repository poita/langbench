package units

import "testing"

func TestFloorDiv(t *testing.T) {
	cases := []struct{ a, b, want int64 }{{7, 2, 3}, {-7, 2, -4}, {-3890 * 850, 5100, -649}, {0, 5, 0}, {-6, 3, -2}}
	for _, c := range cases {
		if got := FloorDiv(c.a, c.b); got != c.want {
			t.Errorf("FloorDiv(%d,%d)=%d want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestScale(t *testing.T) {
	if got := Scale(1563, 10000); got != 15630 {
		t.Errorf("Scale = %d", got)
	}
	if got := Scale(-60, 11000); got != -660 {
		t.Errorf("Scale negative = %d", got)
	}
	if got := Scale(-1, 1); got != -1 {
		t.Errorf("Scale(-1,1) = %d, want -1 (floor)", got)
	}
}

func TestParseLength(t *testing.T) {
	good := map[string]int64{"2.5pt": 2500, "0.5pt": 500, "1.5mm": 4252, "-6pt": -6000, "734": 734,
		"1in": 72000, "2pc": 24000, "1cm": 28350, "0": 0, "3.25": 3}
	for s, want := range good {
		got, ok := ParseLength(s)
		if !ok || got != want {
			t.Errorf("ParseLength(%q) = %d,%v want %d", s, got, ok, want)
		}
	}
	for _, s := range []string{"", "+1pt", "1.2345pt", ".5pt", "5.pt", "5px", "pt", "1 pt", "--1"} {
		if _, ok := ParseLength(s); ok {
			t.Errorf("ParseLength(%q) should fail", s)
		}
	}
}

func TestParseInt(t *testing.T) {
	if v, ok := ParseInt("-12"); !ok || v != -12 {
		t.Errorf("ParseInt(-12) = %d,%v", v, ok)
	}
	for _, s := range []string{"", "+1", "1.0", "-", "1a"} {
		if _, ok := ParseInt(s); ok {
			t.Errorf("ParseInt(%q) should fail", s)
		}
	}
}

func TestRoman(t *testing.T) {
	cases := map[int]string{1: "i", 4: "iv", 9: "ix", 14: "xiv", 40: "xl", 2026: "mmxxvi", 4000: "mmmm", 5001: "mmmmmi"}
	for n, want := range cases {
		if got := Roman(n); got != want {
			t.Errorf("Roman(%d) = %q want %q", n, got, want)
		}
	}
}

func TestLetters(t *testing.T) {
	cases := map[int]string{1: "a", 26: "z", 27: "aa", 28: "ab", 52: "az", 53: "ba"}
	for n, want := range cases {
		if got := Letters(n); got != want {
			t.Errorf("Letters(%d) = %q want %q", n, got, want)
		}
	}
}
