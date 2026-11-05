package toml

// TaggedJSON renders the tree as compact, key-sorted tagged JSON (the
// toml-test interchange format) followed by no newline.
func (t *Table) TaggedJSON() []byte { return t.AppendTaggedJSON(nil) }

// AppendTaggedJSON appends the tagged JSON rendering of t to dst.
func (t *Table) AppendTaggedJSON(dst []byte) []byte {
	return appendJSONNode(dst, t)
}

func appendJSONNode(dst []byte, n Node) []byte {
	switch n := n.(type) {
	case *Table:
		dst = append(dst, '{')
		for i, k := range n.Keys() {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = appendJSONString(dst, k)
			dst = append(dst, ':')
			dst = appendJSONNode(dst, n.m[k])
		}
		return append(dst, '}')
	case *Array:
		dst = append(dst, '[')
		for i, e := range n.Elems {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = appendJSONNode(dst, e)
		}
		return append(dst, ']')
	case *Value:
		dst = append(dst, `{"type":"`...)
		dst = append(dst, n.Type...)
		dst = append(dst, `","value":`...)
		dst = appendJSONString(dst, n.Text)
		return append(dst, '}')
	}
	return dst
}

const hexDigits = "0123456789abcdef"

// appendJSONString appends s as a JSON string literal. Only '"', '\\' and
// code points below U+0020 are escaped; everything else is copied verbatim.
func appendJSONString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
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
