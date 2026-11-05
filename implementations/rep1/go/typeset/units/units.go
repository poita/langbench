// Package units holds the exact integer arithmetic and small text helpers
// shared by every other package: floor division, glyph-space scaling,
// length/integer literal parsing, and the roman/alphabetic numerals used for
// page labels and list markers.
package units

import "strconv"

// Millipoint values of the length units.
const (
	Pt = 1000
	In = 72000
	Pc = 12000
	Mm = 2835
	Cm = 28350
)

// FloorDiv returns a div b (rounding toward negative infinity) for b > 0.
func FloorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && a < 0 {
		q--
	}
	return q
}

// Scale converts a glyph-space quantity u (thousandths of an em) at size s
// millipoints to millipoints: (u*s) div 1000.
func Scale(u, s int64) int64 { return FloorDiv(u*s, 1000) }

const maxLiteral = 1 << 50

func digits(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	var v int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		if v < maxLiteral {
			v = v*10 + int64(c-'0')
		}
	}
	return v, true
}

// ParseInt parses `[-]? DIGITS`. Huge values saturate rather than overflow.
func ParseInt(s string) (int64, bool) {
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		s = s[1:]
	}
	v, ok := digits(s)
	if !ok {
		return 0, false
	}
	if neg {
		v = -v
	}
	return v, true
}

// ParseLength parses a length literal `[-]? DIGITS [. DIGITS] [UNIT]` and
// returns its value in millipoints.
func ParseLength(s string) (int64, bool) {
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		s = s[1:]
	}
	unit := int64(1)
	for _, u := range []struct {
		name string
		mp   int64
	}{{"pt", Pt}, {"mm", Mm}, {"cm", Cm}, {"in", In}, {"pc", Pc}} {
		if len(s) > 2 && s[len(s)-2:] == u.name {
			unit = u.mp
			s = s[:len(s)-2]
			break
		}
	}
	whole, frac := s, ""
	k := int64(0)
	for i := 0; i < len(s); i++ {
		if s[i] == '.' {
			whole, frac = s[:i], s[i+1:]
			if len(frac) < 1 || len(frac) > 3 {
				return 0, false
			}
			k = int64(len(frac))
			break
		}
	}
	w, ok := digits(whole)
	if !ok {
		return 0, false
	}
	var f int64
	if k > 0 {
		if f, ok = digits(frac); !ok {
			return 0, false
		}
	}
	p := int64(1)
	for i := int64(0); i < k; i++ {
		p *= 10
	}
	if w > 1<<30 {
		w = 1 << 30
	}
	v := (w*p + f) * unit / p
	if neg {
		v = -v
	}
	return v, true
}

// Roman returns the lowercase roman numeral of n by the greedy rule; the
// rule is applied unchanged above 3999. n < 1 gives the empty string.
func Roman(n int) string {
	pairs := []struct {
		v int
		s string
	}{{1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"}, {90, "xc"},
		{50, "l"}, {40, "xl"}, {10, "x"}, {9, "ix"}, {5, "v"}, {4, "iv"}, {1, "i"}}
	var b []byte
	for _, p := range pairs {
		for n >= p.v {
			b = append(b, p.s...)
			n -= p.v
		}
	}
	return string(b)
}

// Letters returns the bijective base-26 lowercase letters of n: 1 is "a",
// 26 is "z", 27 is "aa".
func Letters(n int) string {
	var b []byte
	for n > 0 {
		n--
		b = append(b, byte('a'+n%26))
		n /= 26
	}
	for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
	return string(b)
}

// Itoa formats an integer in decimal.
func Itoa(n int64) string { return strconv.FormatInt(n, 10) }
