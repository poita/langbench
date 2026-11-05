package jsonio

import (
	"math"
	"strconv"

	"example.com/jq/value"
)

const hexDigits = "0123456789abcdef"

// Append appends the compact JSON encoding of v to dst and returns the
// extended buffer.
//
// Integral numbers below 2^53 in magnitude print as integers; other numbers
// print in the shortest form that round-trips. Strings escape only what JSON
// requires plus U+007F; everything else is emitted as raw UTF-8. Object keys
// appear in insertion order.
func Append(dst []byte, v value.Value) []byte {
	switch v.Kind() {
	case value.KindNull:
		return append(dst, "null"...)
	case value.KindFalse:
		return append(dst, "false"...)
	case value.KindTrue:
		return append(dst, "true"...)
	case value.KindNumber:
		return AppendNumber(dst, v.Float())
	case value.KindString:
		return AppendString(dst, v.Str())
	case value.KindArray:
		dst = append(dst, '[')
		for i, e := range v.Elems() {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = Append(dst, e)
		}
		return append(dst, ']')
	}
	dst = append(dst, '{')
	for i, e := range v.Obj().Entries() {
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = AppendString(dst, e.Key)
		dst = append(dst, ':')
		dst = Append(dst, e.Val)
	}
	return append(dst, '}')
}

// Marshal returns the compact JSON encoding of v.
func Marshal(v value.Value) string { return string(Append(nil, v)) }

// AppendNumber appends the text of a number.
func AppendNumber(dst []byte, f float64) []byte {
	if f == math.Trunc(f) && math.Abs(f) < 1<<53 {
		return strconv.AppendInt(dst, int64(f), 10)
	}
	switch {
	case math.IsNaN(f):
		return append(dst, "null"...)
	case math.IsInf(f, 1):
		return strconv.AppendFloat(dst, math.MaxFloat64, 'g', -1, 64)
	case math.IsInf(f, -1):
		return strconv.AppendFloat(dst, -math.MaxFloat64, 'g', -1, 64)
	}
	if a := math.Abs(f); a >= 1e-5 && a < 1e17 {
		return strconv.AppendFloat(dst, f, 'f', -1, 64)
	}
	return strconv.AppendFloat(dst, f, 'g', -1, 64)
}

// AppendString appends s as a quoted JSON string.
func AppendString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c != 0x7f {
			continue
		}
		dst = append(dst, s[start:i]...)
		start = i + 1
		switch c {
		case '"':
			dst = append(dst, '\\', '"')
		case '\\':
			dst = append(dst, '\\', '\\')
		case '\b':
			dst = append(dst, '\\', 'b')
		case '\f':
			dst = append(dst, '\\', 'f')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\r':
			dst = append(dst, '\\', 'r')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		}
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}
