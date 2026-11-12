package numeral

import "testing"

func TestRoman(t *testing.T) {
	cases := map[int]string{1: "i", 4: "iv", 9: "ix", 14: "xiv", 40: "xl", 2026: "mmxxvi", 4000: "mmmm", 5001: "mmmmmi"}
	for n, want := range cases {
		if got := Roman(n); got != want {
			t.Errorf("Roman(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestAlpha(t *testing.T) {
	cases := map[int]string{1: "a", 26: "z", 27: "aa", 28: "ab", 52: "az", 53: "ba"}
	for n, want := range cases {
		if got := Alpha(n); got != want {
			t.Errorf("Alpha(%d) = %q, want %q", n, got, want)
		}
	}
}
