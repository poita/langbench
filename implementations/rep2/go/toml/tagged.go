package toml

import (
	"fmt"
	"unicode/utf8"
)

// MarshalTaggedJSON renders n as compact, key-sorted tagged JSON (the toml-test
// interchange format): tables are objects, arrays are arrays and scalars are
// {"type":...,"value":...} objects whose value is always a string.
func MarshalTaggedJSON(n *Node) []byte {
	return AppendTaggedJSON(make([]byte, 0, 256), n)
}

// AppendTaggedJSON appends the tagged JSON form of n to dst.
func AppendTaggedJSON(dst []byte, n *Node) []byte {
	switch n.kind {
	case KindTable:
		dst = append(dst, '{')
		for i, k := range sortedKeys(n.tbl) {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = appendJSONString(dst, k)
			dst = append(dst, ':')
			dst = AppendTaggedJSON(dst, n.tbl[k])
		}
		return append(dst, '}')
	case KindArray:
		dst = append(dst, '[')
		for i, c := range n.items {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = AppendTaggedJSON(dst, c)
		}
		return append(dst, ']')
	}
	dst = append(dst, `{"type":"`...)
	dst = append(dst, n.kind.TypeName()...)
	dst = append(dst, `","value":`...)
	dst = appendJSONString(dst, n.text)
	return append(dst, '}')
}

const hexDigits = "0123456789abcdef"

// appendJSONString appends s as a JSON string literal. Only ", \ and C0
// controls are escaped; everything else (including DEL) is written as is.
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

// ParseTaggedJSON reads a tagged JSON tree. A JSON object is a scalar node
// exactly when it has the two string members "type" (one of the eight type
// names) and "value"; otherwise it is a table. Scalar texts are kept verbatim.
func ParseTaggedJSON(data []byte) (*Node, error) {
	r := &jsonReader{src: data}
	r.skipWS()
	n, err := r.value()
	if err != nil {
		return nil, err
	}
	r.skipWS()
	if r.pos != len(r.src) {
		return nil, r.errorf("trailing data after JSON value")
	}
	if n.kind != KindTable {
		return nil, r.errorf("root must be an object")
	}
	return n, nil
}

type jsonReader struct {
	src []byte
	pos int
}

func (r *jsonReader) errorf(format string, args ...any) error {
	return newError(r.src, r.pos, fmt.Sprintf(format, args...))
}

func (r *jsonReader) skipWS() {
	for r.pos < len(r.src) {
		switch r.src[r.pos] {
		case ' ', '\t', '\n', '\r':
			r.pos++
		default:
			return
		}
	}
}

func (r *jsonReader) value() (*Node, error) {
	if r.pos >= len(r.src) {
		return nil, r.errorf("unexpected end of JSON")
	}
	switch r.src[r.pos] {
	case '{':
		return r.object()
	case '[':
		return r.array()
	case '"':
		s, err := r.str()
		if err != nil {
			return nil, err
		}
		return &Node{kind: kindRaw, text: s}, nil
	}
	return nil, r.errorf("unexpected character in JSON")
}

func (r *jsonReader) object() (*Node, error) {
	r.pos++ // '{'
	tbl := NewTable()
	r.skipWS()
	if r.pos < len(r.src) && r.src[r.pos] == '}' {
		r.pos++
		return tbl, nil
	}
	for {
		r.skipWS()
		if r.pos >= len(r.src) || r.src[r.pos] != '"' {
			return nil, r.errorf("expected object key")
		}
		key, err := r.str()
		if err != nil {
			return nil, err
		}
		r.skipWS()
		if r.pos >= len(r.src) || r.src[r.pos] != ':' {
			return nil, r.errorf("expected ':'")
		}
		r.pos++
		r.skipWS()
		v, err := r.value()
		if err != nil {
			return nil, err
		}
		tbl.tbl[key] = v
		r.skipWS()
		if r.pos >= len(r.src) {
			return nil, r.errorf("unterminated object")
		}
		switch r.src[r.pos] {
		case ',':
			r.pos++
		case '}':
			r.pos++
			return finishObject(tbl), nil
		default:
			return nil, r.errorf("expected ',' or '}'")
		}
	}
}

// finishObject turns a {"type":..,"value":..} table into a scalar node.
func finishObject(tbl *Node) *Node {
	if len(tbl.tbl) == 2 {
		t, v := tbl.tbl["type"], tbl.tbl["value"]
		if t != nil && v != nil && t.kind == kindRaw && v.kind == kindRaw {
			if k, ok := kindFromTypeName(t.text); ok {
				return &Node{kind: k, text: v.text}
			}
		}
	}
	return tbl
}

func (r *jsonReader) array() (*Node, error) {
	r.pos++ // '['
	arr := &Node{kind: KindArray}
	r.skipWS()
	if r.pos < len(r.src) && r.src[r.pos] == ']' {
		r.pos++
		return arr, nil
	}
	for {
		r.skipWS()
		v, err := r.value()
		if err != nil {
			return nil, err
		}
		arr.items = append(arr.items, v)
		r.skipWS()
		if r.pos >= len(r.src) {
			return nil, r.errorf("unterminated array")
		}
		switch r.src[r.pos] {
		case ',':
			r.pos++
		case ']':
			r.pos++
			return arr, nil
		default:
			return nil, r.errorf("expected ',' or ']'")
		}
	}
}

// str reads a JSON string literal; the cursor is on the opening quote.
func (r *jsonReader) str() (string, error) {
	r.pos++
	start := r.pos
	for r.pos < len(r.src) { // fast path: no escapes
		c := r.src[r.pos]
		if c == '"' {
			s := string(r.src[start:r.pos])
			r.pos++
			return s, nil
		}
		if c == '\\' {
			break
		}
		r.pos++
	}
	buf := append([]byte(nil), r.src[start:r.pos]...)
	for r.pos < len(r.src) {
		c := r.src[r.pos]
		switch {
		case c == '"':
			r.pos++
			return string(buf), nil
		case c != '\\':
			buf = append(buf, c)
			r.pos++
			continue
		}
		r.pos++
		if r.pos >= len(r.src) {
			break
		}
		e := r.src[r.pos]
		r.pos++
		switch e {
		case '"', '\\', '/':
			buf = append(buf, e)
		case 'b':
			buf = append(buf, '\b')
		case 'f':
			buf = append(buf, '\f')
		case 'n':
			buf = append(buf, '\n')
		case 'r':
			buf = append(buf, '\r')
		case 't':
			buf = append(buf, '\t')
		case 'u':
			cp, ok := r.hex4()
			if !ok {
				return "", r.errorf("invalid \\u escape")
			}
			if cp >= 0xD800 && cp < 0xDC00 && r.pos+1 < len(r.src) && r.src[r.pos] == '\\' && r.src[r.pos+1] == 'u' {
				save := r.pos
				r.pos += 2
				if lo, ok := r.hex4(); ok && lo >= 0xDC00 && lo < 0xE000 {
					cp = 0x10000 + (cp-0xD800)<<10 + (lo - 0xDC00)
				} else {
					r.pos = save
				}
			}
			buf = utf8.AppendRune(buf, rune(cp))
		default:
			return "", r.errorf("invalid escape in JSON string")
		}
	}
	return "", r.errorf("unterminated JSON string")
}

func (r *jsonReader) hex4() (uint32, bool) {
	if r.pos+4 > len(r.src) {
		return 0, false
	}
	var v uint32
	for _, c := range r.src[r.pos : r.pos+4] {
		var d byte
		switch {
		case c >= '0' && c <= '9':
			d = c - '0'
		case c >= 'a' && c <= 'f':
			d = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			d = c - 'A' + 10
		default:
			return 0, false
		}
		v = v<<4 | uint32(d)
	}
	r.pos += 4
	return v, true
}
