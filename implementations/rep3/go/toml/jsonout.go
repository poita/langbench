package toml

// AppendJSON appends the compact, key-sorted tagged-JSON rendering of n to dst.
//
// Tables become JSON objects, arrays become JSON arrays and scalars become
// {"type":T,"value":TEXT} objects. Keys are ordered by code point.
func (n *Node) AppendJSON(dst []byte) []byte {
	switch n.kind {
	case Table:
		dst = append(dst, '{')
		for i, k := range n.Keys() {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = appendJSONString(dst, k)
			dst = append(dst, ':')
			dst = n.tbl[k].AppendJSON(dst)
		}
		return append(dst, '}')
	case Array:
		dst = append(dst, '[')
		for i, e := range n.arr {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = e.AppendJSON(dst)
		}
		return append(dst, ']')
	}
	dst = append(dst, `{"type":"`...)
	dst = append(dst, n.kind.String()...)
	dst = append(dst, `","value":`...)
	dst = appendJSONString(dst, n.text)
	return append(dst, '}')
}

const hexDigits = "0123456789abcdef"

// appendJSONString appends s as a JSON string literal. Only '"', '\\' and
// code points below U+0020 are escaped; everything else is written as is.
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
