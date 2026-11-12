// Package dim holds the exact integer arithmetic shared by every other
// package: floor division, glyph-space scaling and the parsers for length
// and integer literals.
//
// All quantities in the typesetter are integers. Lengths are measured in
// millipoints (1pt = 1000mp).
package dim

// Millipoint values of the length units.
const (
	Pt = 1000
	Mm = 2835
	Cm = 28350
	In = 72000
	Pc = 12000
)

// FloorDiv returns a div b rounded towards negative infinity. b must be > 0.
func FloorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && a < 0 {
		q--
	}
	return q
}

// Scale converts u thousandths of an em to millipoints at size s:
// (u*s) div 1000.
func Scale(u, s int64) int64 {
	return FloorDiv(u*s, 1000)
}

// Max returns the larger of a and b.
func Max(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// Min returns the smaller of a and b.
func Min(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

const maxDigits = 12

// ParseInteger parses [-]?DIGITS. It reports false for anything else.
func ParseInteger(s string) (int64, bool) {
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		s = s[1:]
	}
	if len(s) == 0 || len(s) > maxDigits {
		return 0, false
	}
	var v int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int64(c-'0')
	}
	if neg {
		v = -v
	}
	return v, true
}

// ParseLength parses a length literal ([-]?DIGITS[.DIGITS][UNIT]) and returns
// its value in millipoints. The fraction has one to three digits and UNIT is
// one of pt, mm, cm, in, pc; no unit means millipoints.
func ParseLength(s string) (int64, bool) {
	i := 0
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i++
	}
	start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == start || i-start > maxDigits {
		return 0, false
	}
	var whole int64
	for _, c := range []byte(s[start:i]) {
		whole = whole*10 + int64(c-'0')
	}
	var frac int64
	pow := int64(1)
	if i < len(s) && s[i] == '.' {
		i++
		fs := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		n := i - fs
		if n < 1 || n > 3 {
			return 0, false
		}
		for _, c := range []byte(s[fs:i]) {
			frac = frac*10 + int64(c-'0')
			pow *= 10
		}
	}
	var unit int64
	switch s[i:] {
	case "":
		unit = 1
	case "pt":
		unit = Pt
	case "mm":
		unit = Mm
	case "cm":
		unit = Cm
	case "in":
		unit = In
	case "pc":
		unit = Pc
	default:
		return 0, false
	}
	v := (whole*pow + frac) * unit / pow
	if neg {
		v = -v
	}
	return v, true
}
