package template

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

// ParseJSON parses one JSON document into a template Value. Unlike
// encoding/json it preserves object member order (objects become *Dict) and
// distinguishes integers (int64) from floats (float64): a number is a float
// iff it has a fraction or exponent part. Nothing but whitespace may follow
// the document.
func ParseJSON(data []byte) (Value, error) {
	p := &jsonParser{s: data}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return nil, err
	}
	p.skipWS()
	if p.pos != len(p.s) {
		return nil, p.errorf("unexpected data after document")
	}
	return v, nil
}

const maxJSONDepth = 10000

type jsonParser struct {
	s   []byte
	pos int
}

func (p *jsonParser) errorf(format string, args ...any) error {
	return fmt.Errorf("json: offset %d: %s", p.pos, fmt.Sprintf(format, args...))
}

func (p *jsonParser) skipWS() {
	for p.pos < len(p.s) {
		switch p.s[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *jsonParser) value(depth int) (Value, error) {
	if depth > maxJSONDepth {
		return nil, p.errorf("nesting too deep")
	}
	if p.pos >= len(p.s) {
		return nil, p.errorf("unexpected end of input")
	}
	switch c := p.s[p.pos]; {
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '"':
		s, err := p.str()
		if err != nil {
			return nil, err
		}
		return s, nil
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case p.literal("true"):
		return true, nil
	case p.literal("false"):
		return false, nil
	case p.literal("null"):
		return None, nil
	}
	return nil, p.errorf("unexpected character %q", p.s[p.pos])
}

func (p *jsonParser) literal(lit string) bool {
	if len(p.s)-p.pos >= len(lit) && string(p.s[p.pos:p.pos+len(lit)]) == lit {
		p.pos += len(lit)
		return true
	}
	return false
}

func (p *jsonParser) object(depth int) (Value, error) {
	p.pos++ // {
	d := NewDict(0)
	p.skipWS()
	if p.pos < len(p.s) && p.s[p.pos] == '}' {
		p.pos++
		return d, nil
	}
	for {
		p.skipWS()
		if p.pos >= len(p.s) || p.s[p.pos] != '"' {
			return nil, p.errorf("expected object key")
		}
		k, err := p.str()
		if err != nil {
			return nil, err
		}
		p.skipWS()
		if p.pos >= len(p.s) || p.s[p.pos] != ':' {
			return nil, p.errorf("expected ':'")
		}
		p.pos++
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return nil, err
		}
		d.Set(k, v)
		p.skipWS()
		if p.pos >= len(p.s) {
			return nil, p.errorf("unterminated object")
		}
		switch p.s[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return d, nil
		default:
			return nil, p.errorf("expected ',' or '}'")
		}
	}
}

func (p *jsonParser) array(depth int) (Value, error) {
	p.pos++ // [
	l := &List{}
	p.skipWS()
	if p.pos < len(p.s) && p.s[p.pos] == ']' {
		p.pos++
		return l, nil
	}
	for {
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return nil, err
		}
		l.Items = append(l.Items, v)
		p.skipWS()
		if p.pos >= len(p.s) {
			return nil, p.errorf("unterminated array")
		}
		switch p.s[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return l, nil
		default:
			return nil, p.errorf("expected ',' or ']'")
		}
	}
}

func (p *jsonParser) number() (Value, error) {
	start := p.pos
	isFloat := false
	if p.s[p.pos] == '-' {
		p.pos++
	}
	digits := func() int {
		n := 0
		for p.pos < len(p.s) && p.s[p.pos] >= '0' && p.s[p.pos] <= '9' {
			p.pos++
			n++
		}
		return n
	}
	if p.pos < len(p.s) && p.s[p.pos] == '0' {
		p.pos++
	} else if digits() == 0 {
		return nil, p.errorf("invalid number")
	}
	if p.pos < len(p.s) && p.s[p.pos] == '.' {
		isFloat = true
		p.pos++
		if digits() == 0 {
			return nil, p.errorf("invalid number")
		}
	}
	if p.pos < len(p.s) && (p.s[p.pos] == 'e' || p.s[p.pos] == 'E') {
		isFloat = true
		p.pos++
		if p.pos < len(p.s) && (p.s[p.pos] == '+' || p.s[p.pos] == '-') {
			p.pos++
		}
		if digits() == 0 {
			return nil, p.errorf("invalid number")
		}
	}
	text := string(p.s[start:p.pos])
	if !isFloat {
		if n, err := strconv.ParseInt(text, 10, 64); err == nil {
			return n, nil
		}
	}
	f, err := strconv.ParseFloat(text, 64)
	if err != nil && f == 0 {
		return nil, p.errorf("invalid number %q", text)
	}
	return f, nil
}

func hex4(b []byte) (rune, bool) {
	if len(b) < 4 {
		return 0, false
	}
	var r rune
	for _, c := range b[:4] {
		switch {
		case c >= '0' && c <= '9':
			r = r<<4 | rune(c-'0')
		case c >= 'a' && c <= 'f':
			r = r<<4 | rune(c-'a'+10)
		case c >= 'A' && c <= 'F':
			r = r<<4 | rune(c-'A'+10)
		default:
			return 0, false
		}
	}
	return r, true
}

func (p *jsonParser) str() (string, error) {
	p.pos++ // opening quote
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if c == '"' {
			s := string(p.s[start:p.pos])
			p.pos++
			return s, nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			return "", p.errorf("control character in string")
		}
		p.pos++
	}
	buf := append([]byte(nil), p.s[start:p.pos]...)
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		switch {
		case c == '"':
			p.pos++
			return string(buf), nil
		case c < 0x20:
			return "", p.errorf("control character in string")
		case c != '\\':
			buf = append(buf, c)
			p.pos++
		default:
			p.pos++
			if p.pos >= len(p.s) {
				return "", p.errorf("unterminated string")
			}
			e := p.s[p.pos]
			p.pos++
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
				r, ok := hex4(p.s[p.pos:])
				if !ok {
					return "", p.errorf("invalid \\u escape")
				}
				p.pos += 4
				if r >= 0xD800 && r < 0xDC00 && p.pos+6 <= len(p.s) && p.s[p.pos] == '\\' && p.s[p.pos+1] == 'u' {
					if r2, ok := hex4(p.s[p.pos+2:]); ok && r2 >= 0xDC00 && r2 < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
						p.pos += 6
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				return "", p.errorf("invalid escape \\%c", e)
			}
		}
	}
	return "", p.errorf("unterminated string")
}
