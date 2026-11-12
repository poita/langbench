package jsonvalue

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// String returns v as compact JSON text. Numbers are printed in the canonical
// form of Number.String, so the text may differ from the original literal but
// denotes the same value.
func (v Value) String() string {
	var sb strings.Builder
	v.write(&sb)
	return sb.String()
}

func (v Value) write(sb *strings.Builder) {
	switch v.kind {
	case Null:
		sb.WriteString("null")
	case Bool:
		sb.WriteString(strconv.FormatBool(v.b))
	case NumberKind:
		sb.WriteString(v.n.String())
	case String:
		writeString(sb, v.s)
	case Array:
		sb.WriteByte('[')
		for i, e := range v.a {
			if i > 0 {
				sb.WriteByte(',')
			}
			e.write(sb)
		}
		sb.WriteByte(']')
	case ObjectKind:
		sb.WriteByte('{')
		for i, k := range v.o.keys {
			if i > 0 {
				sb.WriteByte(',')
			}
			writeString(sb, k)
			sb.WriteByte(':')
			v.o.vals[i].write(sb)
		}
		sb.WriteByte('}')
	}
}

func writeString(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r < 0x20:
			sb.WriteString(`\u00`)
			sb.WriteByte("0123456789abcdef"[r>>4])
			sb.WriteByte("0123456789abcdef"[r&15])
		default:
			sb.WriteString(s[i : i+size])
		}
		i += size
	}
	sb.WriteByte('"')
}
