package value

import "strconv"

const hexDigits = "0123456789abcdef"

// AppendQuoted appends s as a quoted, escaped string (the canonical string
// rendering of the specification) to dst.
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

// AppendRender appends the canonical one-line rendering of v to dst.
func AppendRender(dst []byte, v Value) []byte {
	switch v.Kind {
	case Null:
		return append(dst, "null"...)
	case Bool:
		if v.I != 0 {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case Int:
		return strconv.AppendInt(dst, v.I, 10)
	case String:
		return AppendQuoted(dst, v.S)
	case List:
		dst = append(dst, '[')
		for i := range v.Items {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendRender(dst, v.Items[i])
		}
		return append(dst, ']')
	case Object:
		dst = append(dst, '{')
		for i := range v.Fields {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendQuoted(dst, v.Fields[i].Name)
			dst = append(dst, ':')
			dst = AppendRender(dst, v.Fields[i].Val)
		}
		return append(dst, '}')
	}
	return dst
}

// Render returns the canonical one-line rendering of v: no whitespace, object
// fields in ascending name order, strings escaped as in the specification.
func Render(v Value) string { return string(AppendRender(nil, v)) }
