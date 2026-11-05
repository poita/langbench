// Package numfmt renders numbers the way the spreadsheet displays them.
//
// Zero is "0"; integral values below 1e15 in magnitude are printed as plain
// integers; everything else is printed like C's printf("%.10g") (correctly
// rounded, ties to even).
package numfmt

import (
	"math"
	"strconv"
)

// Append appends the display form of v to dst and returns the extended slice.
// v must be finite.
func Append(dst []byte, v float64) []byte {
	if v == 0 {
		return append(dst, '0')
	}
	if v == math.Floor(v) && math.Abs(v) < 1e15 {
		return strconv.AppendInt(dst, int64(v), 10)
	}
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return strconv.AppendFloat(dst, v, 'g', -1, 64)
	}
	// %.9e: d.ddddddddde±XX, correctly rounded with the exponent taken after
	// rounding.
	var tmp [32]byte
	b := strconv.AppendFloat(tmp[:0], v, 'e', 9, 64)
	if b[0] == '-' {
		dst = append(dst, '-')
		b = b[1:]
	}
	var digits [10]byte
	digits[0] = b[0]
	copy(digits[1:], b[2:11])
	n := 10
	for n > 1 && digits[n-1] == '0' {
		n--
	}
	exp := 0
	for _, c := range b[13:] {
		exp = exp*10 + int(c-'0')
	}
	if b[12] == '-' {
		exp = -exp
	}
	switch {
	case exp < -4 || exp >= 10:
		dst = append(dst, digits[0])
		if n > 1 {
			dst = append(dst, '.')
			dst = append(dst, digits[1:n]...)
		}
		dst = append(dst, 'e')
		if exp < 0 {
			dst = append(dst, '-')
			exp = -exp
		} else {
			dst = append(dst, '+')
		}
		if exp < 10 {
			dst = append(dst, '0')
		}
		dst = strconv.AppendInt(dst, int64(exp), 10)
	case exp >= 0:
		for i := 0; i <= exp; i++ {
			if i < n {
				dst = append(dst, digits[i])
			} else {
				dst = append(dst, '0')
			}
		}
		if n > exp+1 {
			dst = append(dst, '.')
			dst = append(dst, digits[exp+1:n]...)
		}
	default:
		dst = append(dst, '0', '.')
		for i := 0; i < -exp-1; i++ {
			dst = append(dst, '0')
		}
		dst = append(dst, digits[:n]...)
	}
	return dst
}

// Format returns the display form of v.
func Format(v float64) string { return string(Append(nil, v)) }
