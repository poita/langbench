package toml

import (
	"fmt"
	"unicode/utf8"
)

// ParseJSON reads a tagged-JSON tree (the format written by [Node.AppendJSON])
// and returns its root table. Whitespace and member order are free.
//
// A JSON object is a scalar node exactly when it has the two string members
// "type" and "value" and "type" names one of the eight scalar types;
// otherwise it is a table. The value texts are kept verbatim.
func ParseJSON(data []byte) (*Node, error) {
	r := &jsonReader{src: data}
	n, err := r.parseTop()
	if err != nil {
		return nil, err
	}
	return n, nil
}

type jsonReader struct {
	src []byte
	pos int
}

type jsonAbort struct{ err error }

func (r *jsonReader) fail(msg string) {
	panic(jsonAbort{fmt.Errorf("tagged json: %s at offset %d", msg, r.pos)})
}

func (r *jsonReader) parseTop() (n *Node, err error) {
	defer func() {
		if x := recover(); x != nil {
			a, ok := x.(jsonAbort)
			if !ok {
				panic(x)
			}
			n, err = nil, a.err
		}
	}()
	r.skipWS()
	n = r.value()
	r.skipWS()
	if r.pos != len(r.src) {
		r.fail("trailing data")
	}
	if n.kind != Table {
		r.fail("root must be an object")
	}
	return n, nil
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

func (r *jsonReader) value() *Node {
	if r.pos >= len(r.src) {
		r.fail("unexpected end of input")
	}
	switch r.src[r.pos] {
	case '{':
		return r.object()
	case '[':
		return r.array()
	case '"':
		return &Node{kind: kindRaw, text: r.str()}
	}
	r.fail("unexpected character")
	return nil
}

func (r *jsonReader) array() *Node {
	r.pos++
	arr := &Node{kind: Array}
	r.skipWS()
	if r.pos < len(r.src) && r.src[r.pos] == ']' {
		r.pos++
		return arr
	}
	for {
		r.skipWS()
		arr.arr = append(arr.arr, r.value())
		r.skipWS()
		if r.pos >= len(r.src) {
			r.fail("unterminated array")
		}
		c := r.src[r.pos]
		r.pos++
		if c == ']' {
			return arr
		}
		if c != ',' {
			r.fail("expected ',' or ']'")
		}
	}
}

func (r *jsonReader) object() *Node {
	r.pos++
	t := NewTable()
	r.skipWS()
	if r.pos < len(r.src) && r.src[r.pos] == '}' {
		r.pos++
		return t
	}
	for {
		r.skipWS()
		if r.pos >= len(r.src) || r.src[r.pos] != '"' {
			r.fail("expected object key")
		}
		k := r.str()
		r.skipWS()
		if r.pos >= len(r.src) || r.src[r.pos] != ':' {
			r.fail("expected ':'")
		}
		r.pos++
		r.skipWS()
		t.tbl[k] = r.value()
		r.skipWS()
		if r.pos >= len(r.src) {
			r.fail("unterminated object")
		}
		c := r.src[r.pos]
		r.pos++
		if c == '}' {
			break
		}
		if c != ',' {
			r.fail("expected ',' or '}'")
		}
	}
	if len(t.tbl) == 2 {
		ty, ok1 := t.tbl["type"]
		va, ok2 := t.tbl["value"]
		if ok1 && ok2 && ty.kind == kindRaw && va.kind == kindRaw {
			if k, ok := kindByName(ty.text); ok {
				return &Node{kind: k, text: va.text}
			}
		}
	}
	return t
}

// str parses a JSON string literal at the cursor.
func (r *jsonReader) str() string {
	r.pos++ // opening quote
	start := r.pos
	var buf []byte
	for {
		if r.pos >= len(r.src) {
			r.fail("unterminated string")
		}
		c := r.src[r.pos]
		switch {
		case c == '"':
			if buf == nil {
				s := string(r.src[start:r.pos])
				r.pos++
				return s
			}
			r.pos++
			return string(buf)
		case c == '\\':
			if buf == nil {
				buf = append([]byte(nil), r.src[start:r.pos]...)
			}
			r.pos++
			buf = r.jsonEscape(buf)
		default:
			if buf != nil {
				buf = append(buf, c)
			}
			r.pos++
		}
	}
}

func (r *jsonReader) hex4() rune {
	if len(r.src)-r.pos < 4 {
		r.fail("truncated \\u escape")
	}
	var v rune
	for i := 0; i < 4; i++ {
		h, ok := hexVal(r.src[r.pos+i])
		if !ok {
			r.fail("bad hex digit")
		}
		v = v<<4 | rune(h)
	}
	r.pos += 4
	return v
}

func (r *jsonReader) jsonEscape(buf []byte) []byte {
	if r.pos >= len(r.src) {
		r.fail("unterminated escape")
	}
	c := r.src[r.pos]
	r.pos++
	switch c {
	case '"', '\\', '/':
		return append(buf, c)
	case 'b':
		return append(buf, '\b')
	case 'f':
		return append(buf, '\f')
	case 'n':
		return append(buf, '\n')
	case 'r':
		return append(buf, '\r')
	case 't':
		return append(buf, '\t')
	case 'u':
		v := r.hex4()
		if v >= 0xD800 && v < 0xDC00 && len(r.src)-r.pos >= 6 && r.src[r.pos] == '\\' && r.src[r.pos+1] == 'u' {
			save := r.pos
			r.pos += 2
			lo := r.hex4()
			if lo >= 0xDC00 && lo < 0xE000 {
				v = 0x10000 + (v-0xD800)<<10 + (lo - 0xDC00)
			} else {
				r.pos = save
			}
		}
		if v >= 0xD800 && v < 0xE000 {
			v = utf8.RuneError
		}
		return utf8.AppendRune(buf, v)
	}
	r.fail("bad escape")
	return nil
}
