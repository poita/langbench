// Package numfmt implements the number formatting and parsing rules of
// SPEC.md sections 14.3 and 15.2 to 15.3.
package numfmt

import (
	"math"
	"strconv"
)

// FormatFloatAt renders x with exactly digits decimals (0..17 expected),
// exactly as a correctly rounded printf("%.*f") would, with NaN printed as
// "nan" and the infinities as "inf" and "-inf".
func FormatFloatAt(x float64, digits int) string {
	switch {
	case math.IsNaN(x):
		return "nan"
	case math.IsInf(x, 1):
		return "inf"
	case math.IsInf(x, -1):
		return "-inf"
	}
	return strconv.FormatFloat(x, 'f', digits, 64)
}

// FormatIntRadix renders x in the given radix (2..36); the magnitude is
// treated as an unsigned 64-bit value so the minimum integer works.
func FormatIntRadix(x int64, radix int) string {
	if x >= 0 {
		return strconv.FormatUint(uint64(x), radix)
	}
	return "-" + strconv.FormatUint(uint64(-x), radix)
}

func digitValue(c rune) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'z':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'Z':
		return int(c-'A') + 10
	}
	return 99
}

// ParseIntRadix parses an optional sign followed by one or more digits of the
// radix and nothing else. ok is false when the text is malformed or the value
// does not fit in 64 bits.
func ParseIntRadix(s []rune, radix int) (v int64, ok bool) {
	i := 0
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i++
	}
	if i >= len(s) {
		return 0, false
	}
	limit := uint64(math.MaxInt64)
	if neg {
		limit++
	}
	var acc uint64
	for ; i < len(s); i++ {
		d := digitValue(s[i])
		if d >= radix {
			return 0, false
		}
		if acc > (limit-uint64(d))/uint64(radix) {
			return 0, false
		}
		acc = acc*uint64(radix) + uint64(d)
	}
	if neg {
		return int64(-acc), true
	}
	return int64(acc), true
}

// ParseFloat parses the float syntax of section 15.3.
func ParseFloat(s []rune) (float64, bool) {
	i := 0
	n := len(s)
	buf := make([]byte, 0, n)
	if i < n && (s[i] == '+' || s[i] == '-') {
		buf = append(buf, byte(s[i]))
		i++
	}
	isDigit := func(c rune) bool { return c >= '0' && c <= '9' }
	intDigits := 0
	for i < n && isDigit(s[i]) {
		buf = append(buf, byte(s[i]))
		i++
		intDigits++
	}
	fracDigits := 0
	if i < n && s[i] == '.' {
		buf = append(buf, '.')
		i++
		for i < n && isDigit(s[i]) {
			buf = append(buf, byte(s[i]))
			i++
			fracDigits++
		}
	}
	if intDigits == 0 && fracDigits == 0 {
		return 0, false
	}
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		buf = append(buf, 'e')
		i++
		if i < n && (s[i] == '+' || s[i] == '-') {
			buf = append(buf, byte(s[i]))
			i++
		}
		ed := 0
		for i < n && isDigit(s[i]) {
			buf = append(buf, byte(s[i]))
			i++
			ed++
		}
		if ed == 0 {
			return 0, false
		}
	}
	if i != n {
		return 0, false
	}
	f, err := strconv.ParseFloat(string(buf), 64)
	if err != nil {
		if ne, ok := err.(*strconv.NumError); !ok || ne.Err != strconv.ErrRange {
			return 0, false
		}
	}
	return f, true
}
