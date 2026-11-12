package value

import (
	"math"
	"strconv"
)

// Marshal returns the compact JSON text of v: no whitespace, object keys in
// insertion order.
func Marshal(v Value) []byte { return Append(nil, v) }

// String returns the compact JSON text of v as a string.
func String(v Value) string { return string(Append(nil, v)) }

// Append appends the compact JSON text of v to dst and returns the result.
func Append(dst []byte, v Value) []byte {
	switch x := v.(type) {
	case nil:
		return append(dst, "null"...)
	case bool:
		if x {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case float64:
		return AppendNumber(dst, x)
	case string:
		return AppendString(dst, x)
	case []Value:
		dst = append(dst, '[')
		for i, e := range x {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = Append(dst, e)
		}
		return append(dst, ']')
	case *Object:
		dst = append(dst, '{')
		for i, k := range x.keys {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendString(dst, k)
			dst = append(dst, ':')
			dst = Append(dst, x.vals[i])
		}
		return append(dst, '}')
	}
	panic("value: invalid Value type")
}

// FormatNumber returns the text of a number: integral values print as plain
// integers, others in the shortest decimal form that round-trips.
func FormatNumber(f float64) string { return string(AppendNumber(nil, f)) }

// AppendNumber appends the text of f to dst; see FormatNumber. NaN prints as
// null and infinities as the largest finite doubles, as jq does.
func AppendNumber(dst []byte, f float64) []byte {
	switch {
	case math.IsNaN(f):
		return append(dst, "null"...)
	case math.IsInf(f, 1):
		f = math.MaxFloat64
	case math.IsInf(f, -1):
		f = -math.MaxFloat64
	}
	if f == math.Trunc(f) && math.Abs(f) < 1e17 {
		if f == 0 && math.Signbit(f) {
			return append(dst, "-0"...)
		}
		return strconv.AppendInt(dst, int64(f), 10)
	}
	if a := math.Abs(f); a >= 1e-5 && a < 1e17 {
		return strconv.AppendFloat(dst, f, 'f', -1, 64)
	}
	return strconv.AppendFloat(dst, f, 'g', -1, 64)
}

const hexDigits = "0123456789abcdef"

// AppendString appends s as a JSON string literal. Only the quote, the
// backslash and control characters (and U+007F) are escaped; everything else
// is emitted as raw UTF-8.
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
