package toml

// AppendTOML appends the canonical TOML rendering of the table n to dst.
//
// Within each table, key/value pairs are written first (keys in code-point
// order), then sub-tables and arrays of tables with their headers, each
// preceded by a blank line unless nothing has been written yet. Every
// table gets a header, even an empty one. The result ends with a newline.
// It panics if n is not a table.
func (n *Node) AppendTOML(dst []byte) []byte {
	if n.kind != Table {
		panic("toml: AppendTOML on a non-table node")
	}
	e := encoder{buf: dst, start: len(dst)}
	e.table(n, "")
	if len(e.buf) == e.start {
		e.buf = append(e.buf, '\n')
	}
	return e.buf
}

type encoder struct {
	buf   []byte
	start int // length of buf before this document
}

// Member classes inside a table.
const (
	classInline = iota // rendered as "key = value"
	classTable         // rendered with a [header]
	classAoT           // rendered with [[header]] per element
)

func classify(v *Node) int {
	switch v.kind {
	case Table:
		return classTable
	case Array:
		if len(v.arr) == 0 {
			return classInline
		}
		for _, e := range v.arr {
			if e.kind != Table {
				return classInline
			}
		}
		return classAoT
	}
	return classInline
}

func (e *encoder) table(t *Node, path string) {
	keys := t.Keys()
	classes := make([]int, len(keys))
	for i, k := range keys {
		classes[i] = classify(t.tbl[k])
		if classes[i] == classInline {
			e.buf = appendKey(e.buf, k)
			e.buf = append(e.buf, " = "...)
			e.inline(t.tbl[k])
			e.buf = append(e.buf, '\n')
		}
	}
	for i, k := range keys {
		if classes[i] == classInline {
			continue
		}
		sub := path
		if sub != "" {
			sub += "."
		}
		sub += string(appendKey(nil, k))
		v := t.tbl[k]
		if classes[i] == classTable {
			e.header(sub, false)
			e.table(v, sub)
			continue
		}
		for _, el := range v.arr {
			e.header(sub, true)
			e.table(el, sub)
		}
	}
}

func (e *encoder) header(path string, aot bool) {
	if len(e.buf) > e.start {
		e.buf = append(e.buf, '\n')
	}
	if aot {
		e.buf = append(e.buf, "[["...)
	} else {
		e.buf = append(e.buf, '[')
	}
	e.buf = append(e.buf, path...)
	if aot {
		e.buf = append(e.buf, "]]\n"...)
	} else {
		e.buf = append(e.buf, "]\n"...)
	}
}

func (e *encoder) inline(v *Node) {
	switch v.kind {
	case Table:
		e.buf = append(e.buf, '{')
		for i, k := range v.Keys() {
			if i > 0 {
				e.buf = append(e.buf, ", "...)
			}
			e.buf = appendKey(e.buf, k)
			e.buf = append(e.buf, " = "...)
			e.inline(v.tbl[k])
		}
		e.buf = append(e.buf, '}')
	case Array:
		e.buf = append(e.buf, '[')
		for i, el := range v.arr {
			if i > 0 {
				e.buf = append(e.buf, ", "...)
			}
			e.inline(el)
		}
		e.buf = append(e.buf, ']')
	case String:
		e.buf = appendBasicString(e.buf, v.text)
	default:
		e.buf = append(e.buf, v.text...)
	}
}

// appendKey appends k as a bare key if possible, else as a basic string.
func appendKey(dst []byte, k string) []byte {
	if k != "" {
		bare := true
		for i := 0; i < len(k); i++ {
			if !bareKeyByte[k[i]] {
				bare = false
				break
			}
		}
		if bare {
			return append(dst, k...)
		}
	}
	return appendBasicString(dst, k)
}

// appendBasicString appends s as a TOML basic string.
func appendBasicString(dst []byte, s string) []byte {
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
		case '\t':
			dst = append(dst, '\\', 't')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\f':
			dst = append(dst, '\\', 'f')
		case '\r':
			dst = append(dst, '\\', 'r')
		default:
			dst = append(dst, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		}
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}
