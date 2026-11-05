package sqlitefile

import (
	"errors"
	"math"
	"strconv"
)

const hexUpper = "0123456789ABCDEF"

// AppendValue appends v to dst the way the sqlite3 shell prints it in list mode
// with "-nullvalue NULL" and hex-encoded blobs, and returns the extended slice.
func AppendValue(dst []byte, v Value) []byte {
	switch v.Kind {
	case KindNull:
		return append(dst, "NULL"...)
	case KindInteger:
		return strconv.AppendInt(dst, v.I, 10)
	case KindReal:
		return AppendReal(dst, v.F)
	case KindText:
		return append(dst, v.B...)
	}
	for _, c := range v.B {
		dst = append(dst, hexUpper[c>>4], hexUpper[c&15])
	}
	return dst
}

// AppendReal appends f formatted like C's "%.15g" with two adjustments: a
// mantissa without a decimal point gets ".0" appended, and zero (including
// negative zero) prints as "0.0".
func AppendReal(dst []byte, f float64) []byte {
	if f == 0 {
		return append(dst, "0.0"...)
	}
	if math.IsInf(f, 0) || math.IsNaN(f) {
		// Not present in valid databases; print something sensible.
		return strconv.AppendFloat(dst, f, 'g', -1, 64)
	}
	// 15 significant digits in scientific form: [-]d.dddddddddddddde±XX
	var tmp [32]byte
	sci := strconv.AppendFloat(tmp[:0], f, 'e', 14, 64)
	neg := false
	if sci[0] == '-' {
		neg = true
		sci = sci[1:]
	}
	epos := 0
	for i, c := range sci {
		if c == 'e' {
			epos = i
			break
		}
	}
	exp, _ := strconv.Atoi(string(sci[epos+1:]))
	// Digits without the point, trailing zeros trimmed.
	var digits [16]byte
	n := 0
	digits[n] = sci[0]
	n++
	for _, c := range sci[2:epos] {
		digits[n] = c
		n++
	}
	for n > 1 && digits[n-1] == '0' {
		n--
	}
	d := digits[:n]
	if neg {
		dst = append(dst, '-')
	}
	if exp < -4 || exp >= 15 {
		dst = append(dst, d[0], '.')
		if n > 1 {
			dst = append(dst, d[1:]...)
		} else {
			dst = append(dst, '0')
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
		return strconv.AppendInt(dst, int64(exp), 10)
	}
	if exp < 0 {
		dst = append(dst, '0', '.')
		for i := 0; i < -exp-1; i++ {
			dst = append(dst, '0')
		}
		return append(dst, d...)
	}
	// 0 <= exp < 15: integer part has exp+1 digits.
	for i := 0; i <= exp; i++ {
		if i < n {
			dst = append(dst, d[i])
		} else {
			dst = append(dst, '0')
		}
	}
	dst = append(dst, '.')
	if n > exp+1 {
		return append(dst, d[exp+1:]...)
	}
	return append(dst, '0')
}

func parseInt64(s string) (int64, bool) {
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

func parseFloat(s string) (float64, bool) {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil && !errors.Is(err, strconv.ErrRange) {
		return 0, false
	}
	return f, true
}
