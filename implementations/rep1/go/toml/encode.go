package toml

// TOML renders the tree as a canonical TOML document ending in a newline.
//
// Within each table, plain key/value pairs come first in ascending key order,
// followed by sub-tables and arrays of tables (each with a header, preceded
// by a blank line unless it is the first line of the document). Arrays are
// written inline unless they are non-empty arrays of tables.
func (t *Table) TOML() []byte { return t.AppendTOML(nil) }

// AppendTOML appends the canonical TOML rendering of t to dst.
func (t *Table) AppendTOML(dst []byte) []byte {
	e := &encoder{out: dst, base: len(dst)}
	e.table(t, "")
	if len(e.out) == e.base {
		e.out = append(e.out, '\n') // an empty document is a lone newline
	}
	return e.out
}

type encoder struct {
	out  []byte
	base int // length of out before encoding started
}

type memberKind uint8

const (
	kindPair memberKind = iota
	kindTable
	kindArrayOfTables
)

func classify(n Node) memberKind {
	switch n := n.(type) {
	case *Table:
		return kindTable
	case *Array:
		if len(n.Elems) == 0 {
			return kindPair
		}
		for _, e := range n.Elems {
			if _, ok := e.(*Table); !ok {
				return kindPair
			}
		}
		return kindArrayOfTables
	}
	return kindPair
}

func (e *encoder) table(t *Table, path string) {
	keys := t.Keys()
	kinds := make([]memberKind, len(keys))
	for i, k := range keys {
		kinds[i] = classify(t.m[k])
		if kinds[i] == kindPair {
			e.out = appendKey(e.out, k)
			e.out = append(e.out, " = "...)
			e.out = e.inline(e.out, t.m[k])
			e.out = append(e.out, '\n')
		}
	}
	for i, k := range keys {
		if kinds[i] == kindPair {
			continue
		}
		sub := string(appendKey(nil, k))
		if path != "" {
			sub = path + "." + sub
		}
		switch n := t.m[k].(type) {
		case *Table:
			e.header(sub, false)
			e.table(n, sub)
		case *Array:
			for _, el := range n.Elems {
				e.header(sub, true)
				e.table(el.(*Table), sub)
			}
		}
	}
}

func (e *encoder) header(path string, aot bool) {
	if len(e.out) > e.base {
		e.out = append(e.out, '\n')
	}
	if aot {
		e.out = append(e.out, "[["...)
	} else {
		e.out = append(e.out, '[')
	}
	e.out = append(e.out, path...)
	if aot {
		e.out = append(e.out, "]]\n"...)
	} else {
		e.out = append(e.out, "]\n"...)
	}
}

func (e *encoder) inline(dst []byte, n Node) []byte {
	switch n := n.(type) {
	case *Value:
		if n.Type == String {
			return appendQuoted(dst, n.Text)
		}
		return append(dst, n.Text...)
	case *Array:
		dst = append(dst, '[')
		for i, el := range n.Elems {
			if i > 0 {
				dst = append(dst, ", "...)
			}
			dst = e.inline(dst, el)
		}
		return append(dst, ']')
	case *Table:
		dst = append(dst, '{')
		for i, k := range n.Keys() {
			if i > 0 {
				dst = append(dst, ", "...)
			}
			dst = appendKey(dst, k)
			dst = append(dst, " = "...)
			dst = e.inline(dst, n.m[k])
		}
		return append(dst, '}')
	}
	return dst
}

// appendKey appends k as a bare key if possible, otherwise as a basic string.
func appendKey(dst []byte, k string) []byte {
	bare := k != ""
	for i := 0; i < len(k); i++ {
		if !isBareKeyByte(k[i]) {
			bare = false
			break
		}
	}
	if bare {
		return append(dst, k...)
	}
	return appendQuoted(dst, k)
}

// appendQuoted appends s as a TOML basic string.
func appendQuoted(dst []byte, s string) []byte {
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
