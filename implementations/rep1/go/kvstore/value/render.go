package value

import "strconv"

const hexDigits = "0123456789abcdef"

// Render returns the canonical single-line rendering of v (no whitespace).
func Render(v Value) string { return string(AppendRender(nil, v)) }

// AppendRender appends the canonical rendering of v to dst.
func AppendRender(dst []byte, v Value) []byte {
	switch v.Kind {
	case Null:
		return append(dst, "null"...)
	case Bool:
		if v.Bool {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case Int:
		return strconv.AppendInt(dst, v.Int, 10)
	case String:
		return AppendQuoted(dst, v.Str)
	case List:
		dst = append(dst, '[')
		for i, e := range v.List {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendRender(dst, e)
		}
		return append(dst, ']')
	default:
		dst = append(dst, '{')
		for i, f := range v.Fields {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendQuoted(dst, f.Name)
			dst = append(dst, ':')
			dst = AppendRender(dst, f.Value)
		}
		return append(dst, '}')
	}
}

// AppendQuoted appends s as a double-quoted, escaped string. Control
// characters and DEL are escaped, "/" is not, and non-ASCII text is written
// as is.
func AppendQuoted(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			dst = append(dst, '\\', '"')
		case c == '\\':
			dst = append(dst, '\\', '\\')
		case c == '\b':
			dst = append(dst, '\\', 'b')
		case c == '\t':
			dst = append(dst, '\\', 't')
		case c == '\n':
			dst = append(dst, '\\', 'n')
		case c == '\f':
			dst = append(dst, '\\', 'f')
		case c == '\r':
			dst = append(dst, '\\', 'r')
		case c < 0x20 || c == 0x7f:
			dst = append(dst, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		default:
			dst = append(dst, c)
		}
	}
	return append(dst, '"')
}
