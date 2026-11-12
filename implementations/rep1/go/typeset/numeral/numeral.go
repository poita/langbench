// Package numeral formats the integers used as page labels and list markers.
package numeral

import "strings"

var romanPairs = []struct {
	v int
	s string
}{
	{1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"}, {90, "xc"},
	{50, "l"}, {40, "xl"}, {10, "x"}, {9, "ix"}, {5, "v"}, {4, "iv"}, {1, "i"},
}

// Roman returns n as a lowercase roman numeral by greedy subtraction. The
// rule is applied unchanged above 3999, so 4000 is "mmmm".
func Roman(n int) string {
	var b strings.Builder
	for _, p := range romanPairs {
		for n >= p.v {
			b.WriteString(p.s)
			n -= p.v
		}
	}
	return b.String()
}

// Alpha returns n (>= 1) in lowercase bijective base 26: 1 is "a", 26 is "z",
// 27 is "aa".
func Alpha(n int) string {
	var out []byte
	for n > 0 {
		n--
		out = append(out, byte('a'+n%26))
		n /= 26
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return string(out)
}
