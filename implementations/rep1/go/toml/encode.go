package toml

import (
	"strings"
)

// Encode renders root as a canonical TOML document.
//
// Within each table, key/value pairs come first in ascending key order,
// followed by sub-tables and arrays of tables, also in key order; every
// table gets a header, a blank line precedes every header except one on the
// first line, and arrays are written inline unless they are non-empty and
// consist only of tables. Strings are always basic strings. Scalars are
// written from their canonical text, so Encode never converts a number or
// date.
func Encode(root *Table) []byte {
	var e encoder
	e.table(root, "")
	if e.sb.Len() == 0 {
		return []byte("\n")
	}
	return []byte(e.sb.String())
}

type encoder struct {
	sb strings.Builder
}

// isArrayOfTables reports whether a is a non-empty array of tables only.
func isArrayOfTables(a *Array) bool {
	if len(a.Items) == 0 {
		return false
	}
	for _, it := range a.Items {
		if _, ok := it.(*Table); !ok {
			return false
		}
	}
	return true
}

func (e *encoder) table(t *Table, path string) {
	keys := t.Keys()
	for _, k := range keys {
		n := t.entries[k]
		if isSection(n) {
			continue
		}
		e.sb.WriteString(encodeKey(k))
		e.sb.WriteString(" = ")
		e.inline(n)
		e.sb.WriteByte('\n')
	}
	for _, k := range keys {
		n := t.entries[k]
		if !isSection(n) {
			continue
		}
		sub := encodeKey(k)
		if path != "" {
			sub = path + "." + sub
		}
		switch n := n.(type) {
		case *Table:
			e.header("[" + sub + "]")
			e.table(n, sub)
		case *Array:
			for _, it := range n.Items {
				e.header("[[" + sub + "]]")
				e.table(it.(*Table), sub)
			}
		}
	}
}

func isSection(n Node) bool {
	switch n := n.(type) {
	case *Table:
		return true
	case *Array:
		return isArrayOfTables(n)
	}
	return false
}

func (e *encoder) header(h string) {
	if e.sb.Len() > 0 {
		e.sb.WriteByte('\n')
	}
	e.sb.WriteString(h)
	e.sb.WriteByte('\n')
}

func (e *encoder) inline(n Node) {
	switch n := n.(type) {
	case *Value:
		if n.Type == TypeString {
			quote(&e.sb, n.Text)
		} else {
			e.sb.WriteString(n.Text)
		}
	case *Array:
		e.sb.WriteByte('[')
		for i, it := range n.Items {
			if i > 0 {
				e.sb.WriteString(", ")
			}
			e.inline(it)
		}
		e.sb.WriteByte(']')
	case *Table:
		e.sb.WriteByte('{')
		for i, k := range n.Keys() {
			if i > 0 {
				e.sb.WriteString(", ")
			}
			e.sb.WriteString(encodeKey(k))
			e.sb.WriteString(" = ")
			e.inline(n.entries[k])
		}
		e.sb.WriteByte('}')
	}
}

func encodeKey(k string) string {
	if k != "" {
		bare := true
		for i := 0; i < len(k); i++ {
			if !isBareKeyChar(k[i]) {
				bare = false
				break
			}
		}
		if bare {
			return k
		}
	}
	var sb strings.Builder
	quote(&sb, k)
	return sb.String()
}

const hexDigits = "0123456789abcdef"

// quote writes s as a TOML basic string.
func quote(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			sb.WriteString(`\"`)
		case c == '\\':
			sb.WriteString(`\\`)
		case c == '\b':
			sb.WriteString(`\b`)
		case c == '\t':
			sb.WriteString(`\t`)
		case c == '\n':
			sb.WriteString(`\n`)
		case c == '\f':
			sb.WriteString(`\f`)
		case c == '\r':
			sb.WriteString(`\r`)
		case c < 0x20 || c == 0x7f:
			sb.WriteString(`\u00`)
			sb.WriteByte(hexDigits[c>>4])
			sb.WriteByte(hexDigits[c&15])
		default:
			sb.WriteByte(c)
		}
	}
	sb.WriteByte('"')
}
