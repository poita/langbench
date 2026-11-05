package value

import (
	"strconv"
)

const hexDigits = "0123456789abcdef"

// AppendJSON appends the compact JSON text of v to dst and returns the
// extended slice. Object members are written in insertion order.
func AppendJSON(dst []byte, v Value) []byte {
	switch v.kind {
	case KindNull:
		return append(dst, "null"...)
	case KindFalse:
		return append(dst, "false"...)
	case KindTrue:
		return append(dst, "true"...)
	case KindNumber:
		return AppendNumber(dst, v.num)
	case KindString:
		return AppendQuoted(dst, v.Str())
	case KindArray:
		dst = append(dst, '[')
		for i, e := range v.Items() {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendJSON(dst, e)
		}
		return append(dst, ']')
	}
	o := v.Obj()
	dst = append(dst, '{')
	for i, k := range o.keys {
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = AppendQuoted(dst, k)
		dst = append(dst, ':')
		dst = AppendJSON(dst, o.vals[i])
	}
	return append(dst, '}')
}

// JSON returns the compact JSON text of v.
func JSON(v Value) string { return string(AppendJSON(nil, v)) }

// AppendNumber appends the text of f: integral values below 2^53 print as
// integers, everything else in the shortest decimal form that round-trips.
func AppendNumber(dst []byte, f float64) []byte {
	if f == float64(int64(f)) && f > -9007199254740992 && f < 9007199254740992 {
		return strconv.AppendInt(dst, int64(f), 10)
	}
	abs := f
	if abs < 0 {
		abs = -abs
	}
	if abs >= 1e-5 && abs < 1e17 {
		return strconv.AppendFloat(dst, f, 'f', -1, 64)
	}
	return strconv.AppendFloat(dst, f, 'g', -1, 64)
}

// AppendQuoted appends s as a JSON string literal.
func AppendQuoted(dst []byte, s string) []byte {
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
