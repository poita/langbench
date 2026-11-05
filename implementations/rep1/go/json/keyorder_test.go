package jsoncanon

import (
	"sort"
	"testing"
	"unicode/utf16"
)

func utf16Less(a, b string) bool {
	ua, ub := utf16.Encode([]rune(a)), utf16.Encode([]rune(b))
	for i := 0; i < len(ua) && i < len(ub); i++ {
		if ua[i] != ub[i] {
			return ua[i] < ub[i]
		}
	}
	return len(ua) < len(ub)
}

func sign(x int) int {
	switch {
	case x < 0:
		return -1
	case x > 0:
		return 1
	}
	return 0
}

func TestCompareKeysMatchesUTF16(t *testing.T) {
	keys := []string{"", "Z", "a", "a\x00", "aa", "é", "éa", "ß", "\u07ff", "\u0800", "\ud7ff",
		"😀", "😀a", "\U00010000", "\U0010ffff", "\ue000", "\uffff", "a😀", "a\uffff", "a\ue000", "ab"}
	for _, a := range keys {
		for _, b := range keys {
			want := 0
			if utf16Less(a, b) {
				want = -1
			} else if utf16Less(b, a) {
				want = 1
			}
			if got := sign(compareKeys([]byte(a), []byte(b))); got != want {
				t.Errorf("compareKeys(%q,%q) = %d, want %d", a, b, got, want)
			}
		}
	}
	sorted := append([]string(nil), keys...)
	sort.Slice(sorted, func(i, j int) bool { return compareKeys([]byte(sorted[i]), []byte(sorted[j])) < 0 })
	for i := 1; i < len(sorted); i++ {
		if utf16Less(sorted[i], sorted[i-1]) {
			t.Errorf("misordered %q before %q", sorted[i-1], sorted[i])
		}
	}
}
