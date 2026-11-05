package codec

import (
	"strconv"

	"protowire/schema"
	"protowire/wire"
)

// renderer appends the canonical text of a value tree. buf is the byte
// buffer that string/bytes views point into.
type renderer struct {
	buf    []byte
	schema *schema.Schema
}

func (r *renderer) message(dst []byte, m *schema.MessageType, n *node) []byte {
	dst = append(dst, '{')
	first := true
	for i := range m.Fields {
		f := &m.Fields[i]
		s := &n.slots[i]
		switch {
		case f.Repeated:
			if s.list.count(f.Kind) == 0 {
				continue
			}
		case f.Kind == schema.Message:
			if s.child == nil {
				continue
			}
		case f.Kind.IsBytesLike():
			if viewLen(s.n) == 0 {
				continue
			}
		default:
			if s.n == 0 {
				continue
			}
		}
		if !first {
			dst = append(dst, ',', ' ')
		}
		first = false
		dst = append(dst, f.Name...)
		dst = append(dst, ':', ' ')
		if f.Repeated {
			dst = append(dst, '[')
			l := s.list
			if f.Kind == schema.Message {
				sub := &r.schema.Messages[f.Message]
				for j, c := range l.nodes {
					if j > 0 {
						dst = append(dst, ',', ' ')
					}
					dst = r.message(dst, sub, c)
				}
			} else {
				for j, v := range l.nums {
					if j > 0 {
						dst = append(dst, ',', ' ')
					}
					dst = r.scalar(dst, f.Kind, v)
				}
			}
			dst = append(dst, ']')
		} else if f.Kind == schema.Message {
			dst = r.message(dst, &r.schema.Messages[f.Message], s.child)
		} else {
			dst = r.scalar(dst, f.Kind, s.n)
		}
	}
	return append(dst, '}')
}

// scalar renders one non-message value.
func (r *renderer) scalar(dst []byte, k schema.Kind, v uint64) []byte {
	switch {
	case k == schema.Bool:
		if v != 0 {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case k == schema.String:
		off, n := viewParts(v)
		return appendQuoted(dst, r.buf[off:off+n])
	case k == schema.BytesKind:
		off, n := viewParts(v)
		dst = append(dst, 'x', '"')
		dst = wire.AppendHex(dst, r.buf[off:off+n])
		return append(dst, '"')
	case k.Signed():
		return strconv.AppendInt(dst, int64(v), 10)
	}
	return strconv.AppendUint(dst, v, 10)
}

const hexDigits = "0123456789abcdef"

// appendQuoted appends s as a double-quoted literal using the canonical
// escapes. Runs of bytes needing no escape are copied in bulk.
func appendQuoted(dst, s []byte) []byte {
	dst = append(dst, '"')
	start := 0
	for i, c := range s {
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
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\r':
			dst = append(dst, '\\', 'r')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, '\\', 'x', hexDigits[c>>4], hexDigits[c&15])
		}
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}
