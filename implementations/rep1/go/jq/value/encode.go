package value

import (
	"math"
	"strconv"
	"unicode/utf8"
)

const hexDigits = "0123456789abcdef"

// AppendJSON appends the compact JSON text of v to buf and returns the
// extended buffer. Object members are written in insertion order.
func AppendJSON(buf []byte, v Value) []byte {
	switch v.kind {
	case KindNull:
		return append(buf, "null"...)
	case KindFalse:
		return append(buf, "false"...)
	case KindTrue:
		return append(buf, "true"...)
	case KindNumber:
		return AppendNumber(buf, v.num)
	case KindString:
		return AppendQuoted(buf, v.Str())
	case KindArray:
		buf = append(buf, '[')
		for i, e := range v.Elems() {
			if i > 0 {
				buf = append(buf, ',')
			}
			buf = AppendJSON(buf, e)
		}
		return append(buf, ']')
	default:
		buf = append(buf, '{')
		for i, e := range v.Object().entries {
			if i > 0 {
				buf = append(buf, ',')
			}
			buf = AppendQuoted(buf, e.Key)
			buf = append(buf, ':')
			buf = AppendJSON(buf, e.Value)
		}
		return append(buf, '}')
	}
}

// JSON returns the compact JSON text of v.
func JSON(v Value) string { return string(AppendJSON(nil, v)) }

// AppendNumber appends f the way jq -c prints numbers: integral values below
// 2^53 as plain integers, everything else in the shortest decimal form that
// round-trips.
func AppendNumber(buf []byte, f float64) []byte {
	if f == math.Trunc(f) && math.Abs(f) < 1<<53 {
		return strconv.AppendInt(buf, int64(f), 10)
	}
	switch {
	case math.IsNaN(f):
		return append(buf, "null"...)
	case math.IsInf(f, 1):
		return append(buf, "1.7976931348623157e+308"...)
	case math.IsInf(f, -1):
		return append(buf, "-1.7976931348623157e+308"...)
	}
	if a := math.Abs(f); a < 1e-5 || a >= 1e17 {
		return strconv.AppendFloat(buf, f, 'g', -1, 64)
	}
	return strconv.AppendFloat(buf, f, 'f', -1, 64)
}

// AppendQuoted appends s as a JSON string literal: control characters and
// U+007F are written as escapes, everything else is copied as is.
func AppendQuoted(buf []byte, s string) []byte {
	buf = append(buf, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c != 0x7f {
			continue
		}
		buf = append(buf, s[start:i]...)
		start = i + 1
		switch c {
		case '"':
			buf = append(buf, '\\', '"')
		case '\\':
			buf = append(buf, '\\', '\\')
		case '\b':
			buf = append(buf, '\\', 'b')
		case '\f':
			buf = append(buf, '\\', 'f')
		case '\n':
			buf = append(buf, '\\', 'n')
		case '\r':
			buf = append(buf, '\\', 'r')
		case '\t':
			buf = append(buf, '\\', 't')
		default:
			buf = append(buf, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		}
	}
	buf = append(buf, s[start:]...)
	return append(buf, '"')
}

// AppendRune appends r as UTF-8 (helper shared with the string decoder).
func appendRune(buf []byte, r rune) []byte { return utf8.AppendRune(buf, r) }
