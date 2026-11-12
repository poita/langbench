package spreadsheet

import (
	"math"
	"strconv"
	"strings"
)

// FormatNumber returns the display form of a number: "0" for zero, a plain
// integer for integral values below 1e15 in magnitude, and otherwise the
// equivalent of C's printf("%.10g").
func FormatNumber(v float64) string {
	if v == 0 {
		return "0"
	}
	if v == math.Trunc(v) && math.Abs(v) < 1e15 {
		return strconv.FormatInt(int64(v), 10)
	}
	// d.ddddddddde±XX: exactly rounded to 10 significant digits, ties to even.
	s := strconv.FormatFloat(v, 'e', 9, 64)
	neg := false
	if s[0] == '-' {
		neg = true
		s = s[1:]
	}
	epos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[epos+1:])
	digits := strings.TrimRight(s[:1]+s[2:epos], "0")
	if digits == "" {
		digits = "0"
	}
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	switch {
	case exp < -4 || exp >= 10:
		b.WriteByte(digits[0])
		if len(digits) > 1 {
			b.WriteByte('.')
			b.WriteString(digits[1:])
		}
		b.WriteByte('e')
		if exp < 0 {
			b.WriteByte('-')
			exp = -exp
		} else {
			b.WriteByte('+')
		}
		if exp < 10 {
			b.WriteByte('0')
		}
		b.WriteString(strconv.Itoa(exp))
	case exp >= 0:
		if len(digits) <= exp+1 {
			b.WriteString(digits)
			b.WriteString(strings.Repeat("0", exp+1-len(digits)))
		} else {
			b.WriteString(digits[:exp+1])
			b.WriteByte('.')
			b.WriteString(digits[exp+1:])
		}
	default:
		b.WriteString("0.")
		b.WriteString(strings.Repeat("0", -exp-1))
		b.WriteString(digits)
	}
	return b.String()
}
