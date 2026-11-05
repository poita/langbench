package toml

import (
	"errors"
)

// MarshalTOML renders the root table n as canonical TOML: within each table,
// plain key/value pairs come first in key order, followed by sub-tables and
// arrays of tables (each with an explicit header) in key order. Scalars are
// written from their canonical text, strings as basic strings.
func MarshalTOML(n *Node) ([]byte, error) {
	if n == nil || n.kind != KindTable {
		return nil, errors.New("toml: root must be a table")
	}
	e := &encoder{out: make([]byte, 0, 1024)}
	e.table(n, "")
	if len(e.out) == 0 {
		e.out = append(e.out, '\n')
	}
	return e.out, nil
}

type encoder struct {
	out []byte
}

// isArrayOfTables reports whether n is a non-empty array whose elements are all tables.
func isArrayOfTables(n *Node) bool {
	if n.kind != KindArray || len(n.items) == 0 {
		return false
	}
	for _, c := range n.items {
		if c.kind != KindTable {
			return false
		}
	}
	return true
}

func (e *encoder) header(open, closing string, path string) {
	if len(e.out) > 0 {
		e.out = append(e.out, '\n')
	}
	e.out = append(e.out, open...)
	e.out = append(e.out, path...)
	e.out = append(e.out, closing...)
	e.out = append(e.out, '\n')
}

func (e *encoder) table(t *Node, path string) {
	keys := sortedKeys(t.tbl)
	// Classification is a cheap check; it is done once per key and remembered.
	nested := make([]bool, len(keys))
	anyNested := false
	for i, k := range keys {
		c := t.tbl[k]
		if c.kind == KindTable || isArrayOfTables(c) {
			nested[i] = true
			anyNested = true
			continue
		}
		e.out = appendKey(e.out, k)
		e.out = append(e.out, " = "...)
		e.inline(c)
		e.out = append(e.out, '\n')
	}
	if !anyNested {
		return
	}
	for i, k := range keys {
		if !nested[i] {
			continue
		}
		sub := string(appendKey(nil, k))
		if path != "" {
			sub = path + "." + sub
		}
		c := t.tbl[k]
		if c.kind == KindTable {
			e.header("[", "]", sub)
			e.table(c, sub)
			continue
		}
		for _, el := range c.items {
			e.header("[[", "]]", sub)
			e.table(el, sub)
		}
	}
}

func (e *encoder) inline(n *Node) {
	switch n.kind {
	case KindTable:
		e.out = append(e.out, '{')
		for i, k := range sortedKeys(n.tbl) {
			if i > 0 {
				e.out = append(e.out, ", "...)
			}
			e.out = appendKey(e.out, k)
			e.out = append(e.out, " = "...)
			e.inline(n.tbl[k])
		}
		e.out = append(e.out, '}')
	case KindArray:
		e.out = append(e.out, '[')
		for i, c := range n.items {
			if i > 0 {
				e.out = append(e.out, ", "...)
			}
			e.inline(c)
		}
		e.out = append(e.out, ']')
	case KindString:
		e.out = appendBasicString(e.out, n.text)
	default:
		e.out = append(e.out, n.text...)
	}
}

// appendKey appends k as a bare key if possible, else as a basic string.
func appendKey(dst []byte, k string) []byte {
	if k != "" {
		bare := true
		for i := 0; i < len(k); i++ {
			if !isBareKeyByte(k[i]) {
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

// appendBasicString appends s as a TOML basic string, escaping only what must be.
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
