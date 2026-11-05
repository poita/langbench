package toml

import (
	"fmt"
	"unicode/utf8"
)

// ParseTaggedJSON reads a tagged JSON tree (the format produced by
// [Table.TaggedJSON]) into a tree. Object members may appear in any order and
// any JSON whitespace is accepted. An object with exactly the two string
// members "type" and "value", where "type" names a scalar type, is a scalar;
// every other object is a table.
func ParseTaggedJSON(src []byte) (*Table, error) {
	r := &jsonReader{src: src}
	r.ws()
	n, err := r.node()
	if err != nil {
		return nil, err
	}
	r.ws()
	if r.pos != len(src) {
		return nil, r.errorf("trailing data after JSON value")
	}
	t, ok := n.(*Table)
	if !ok {
		return nil, r.errorf("root must be a JSON object")
	}
	return t, nil
}

type jsonReader struct {
	src []byte
	pos int
}

func (r *jsonReader) errorf(format string, args ...any) error {
	return fmt.Errorf("tagged json: offset %d: %s", r.pos, fmt.Sprintf(format, args...))
}

func (r *jsonReader) ws() {
	for r.pos < len(r.src) {
		switch r.src[r.pos] {
		case ' ', '\t', '\n', '\r':
			r.pos++
		default:
			return
		}
	}
}

func (r *jsonReader) node() (Node, error) {
	if r.pos >= len(r.src) {
		return nil, r.errorf("unexpected end of input")
	}
	switch r.src[r.pos] {
	case '{':
		return r.object()
	case '[':
		return r.array()
	}
	return nil, r.errorf("expected object or array")
}

func (r *jsonReader) array() (Node, error) {
	r.pos++
	arr := &Array{}
	r.ws()
	if r.pos < len(r.src) && r.src[r.pos] == ']' {
		r.pos++
		return arr, nil
	}
	for {
		r.ws()
		n, err := r.node()
		if err != nil {
			return nil, err
		}
		arr.Elems = append(arr.Elems, n)
		r.ws()
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

func (r *jsonReader) object() (Node, error) {
	r.pos++
	t := NewTable()
	var typ, val string
	var haveTyp, haveVal bool
	members, strMembers := 0, 0
	r.ws()
	if r.pos < len(r.src) && r.src[r.pos] == '}' {
		r.pos++
		return t, nil
	}
	for {
		r.ws()
		if r.pos >= len(r.src) || r.src[r.pos] != '"' {
			return nil, r.errorf("expected object key")
		}
		key, err := r.str()
		if err != nil {
			return nil, err
		}
		r.ws()
		if r.pos >= len(r.src) || r.src[r.pos] != ':' {
			return nil, r.errorf("expected ':'")
		}
		r.pos++
		r.ws()
		members++
		if r.pos < len(r.src) && r.src[r.pos] == '"' {
			s, err := r.str()
			if err != nil {
				return nil, err
			}
			strMembers++
			switch key {
			case "type":
				typ, haveTyp = s, true
			case "value":
				val, haveVal = s, true
			}
		} else {
			n, err := r.node()
			if err != nil {
				return nil, err
			}
			t.m[key] = n
		}
		r.ws()
		if r.pos >= len(r.src) {
			return nil, r.errorf("unterminated object")
		}
		switch r.src[r.pos] {
		case ',':
			r.pos++
			continue
		case '}':
			r.pos++
		default:
			return nil, r.errorf("expected ',' or '}'")
		}
		break
	}
	if members == 2 && haveTyp && haveVal && ValueType(typ).valid() {
		return &Value{ValueType(typ), val}, nil
	}
	if strMembers > 0 {
		return nil, r.errorf("string member in a table")
	}
	return t, nil
}

// str parses a JSON string at the cursor (which is on the opening quote).
func (r *jsonReader) str() (string, error) {
	src := r.src
	r.pos++
	start := r.pos
	var buf []byte
	escaped := false
	for {
		if r.pos >= len(src) {
			return "", r.errorf("unterminated string")
		}
		c := src[r.pos]
		switch {
		case c == '"':
			var s string
			if escaped {
				buf = append(buf, src[start:r.pos]...)
				s = string(buf)
			} else {
				s = string(src[start:r.pos])
			}
			r.pos++
			return s, nil
		case c == '\\':
			if !escaped {
				escaped = true
			}
			buf = append(buf, src[start:r.pos]...)
			r.pos++
			if r.pos >= len(src) {
				return "", r.errorf("unterminated escape")
			}
			e := src[r.pos]
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
				u, err := r.hex4()
				if err != nil {
					return "", err
				}
				if u >= 0xD800 && u < 0xDC00 && r.pos+1 < len(src) && src[r.pos] == '\\' && src[r.pos+1] == 'u' {
					save := r.pos
					r.pos += 2
					lo, err := r.hex4()
					if err == nil && lo >= 0xDC00 && lo < 0xE000 {
						u = 0x10000 + (u-0xD800)<<10 + (lo - 0xDC00)
					} else {
						r.pos = save
					}
				}
				buf = utf8.AppendRune(buf, rune(u)) // lone surrogates become U+FFFD
			default:
				return "", r.errorf("invalid escape")
			}
			start = r.pos
		case c < 0x20:
			return "", r.errorf("control character in string")
		default:
			r.pos++
		}
	}
}

func (r *jsonReader) hex4() (rune, error) {
	if r.pos+4 > len(r.src) {
		return 0, r.errorf("truncated \\u escape")
	}
	var u rune
	for i := 0; i < 4; i++ {
		d, ok := hexVal(r.src[r.pos+i])
		if !ok {
			return 0, r.errorf("invalid \\u escape")
		}
		u = u<<4 | rune(d)
	}
	r.pos += 4
	return u, nil
}
