package value

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

// SyntaxError describes malformed JSON input.
type SyntaxError struct {
	Offset int
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("json: %s at offset %d", e.Msg, e.Offset)
}

// Parse parses exactly one JSON value (RFC 8259) from data, allowing
// surrounding whitespace. Numbers become the nearest double; object members
// keep document order and object keys are interned.
func Parse(data []byte) (Value, error) {
	p := parser{data: data, keys: Interner{}}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return Null, err
	}
	p.skipWS()
	if p.pos != len(p.data) {
		return Null, p.errf("unexpected trailing data")
	}
	return v, nil
}

// ParseString is Parse for a string.
func ParseString(s string) (Value, error) { return Parse([]byte(s)) }

const maxDepth = 10000

type parser struct {
	data []byte
	pos  int
	keys Interner
	buf  []byte
}

func (p *parser) errf(msg string) error { return &SyntaxError{p.pos, msg} }

func (p *parser) skipWS() {
	for p.pos < len(p.data) {
		switch p.data[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) literal(word string, v Value) (Value, error) {
	if p.pos+len(word) <= len(p.data) && string(p.data[p.pos:p.pos+len(word)]) == word {
		p.pos += len(word)
		return v, nil
	}
	return Null, p.errf("invalid literal")
}

func (p *parser) value(depth int) (Value, error) {
	if p.pos >= len(p.data) {
		return Null, p.errf("unexpected end of input")
	}
	if depth > maxDepth {
		return Null, p.errf("nesting too deep")
	}
	switch c := p.data[p.pos]; {
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '"':
		s, err := p.str(false)
		if err != nil {
			return Null, err
		}
		return String(s), nil
	case c == 't':
		return p.literal("true", True)
	case c == 'f':
		return p.literal("false", False)
	case c == 'n':
		return p.literal("null", Null)
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	}
	return Null, p.errf("unexpected character")
}

func (p *parser) number() (Value, error) {
	start := p.pos
	d := p.data
	i := p.pos
	neg := false
	if d[i] == '-' {
		neg = true
		i++
	}
	ds := i
	for i < len(d) && d[i] >= '0' && d[i] <= '9' {
		i++
	}
	if i == ds {
		return Null, p.errf("invalid number")
	}
	if d[ds] == '0' && i-ds > 1 {
		return Null, p.errf("invalid number")
	}
	intEnd := i
	simple := true
	if i < len(d) && d[i] == '.' {
		simple = false
		i++
		fs := i
		for i < len(d) && d[i] >= '0' && d[i] <= '9' {
			i++
		}
		if i == fs {
			return Null, p.errf("invalid number")
		}
	}
	if i < len(d) && (d[i] == 'e' || d[i] == 'E') {
		simple = false
		i++
		if i < len(d) && (d[i] == '+' || d[i] == '-') {
			i++
		}
		es := i
		for i < len(d) && d[i] >= '0' && d[i] <= '9' {
			i++
		}
		if i == es {
			return Null, p.errf("invalid number")
		}
	}
	p.pos = i
	if simple && intEnd-ds <= 15 {
		var n int64
		for _, c := range d[ds:intEnd] {
			n = n*10 + int64(c-'0')
		}
		if neg {
			n = -n
		}
		return Number(float64(n)), nil
	}
	f, err := strconv.ParseFloat(string(d[start:i]), 64)
	if err != nil {
		// Out-of-range values yield ±Inf together with an error; keep them.
		if ne, ok := err.(*strconv.NumError); !ok || ne.Err != strconv.ErrRange {
			return Null, p.errf("invalid number")
		}
	}
	return Number(f), nil
}

// str parses a string literal starting at the opening quote.
func (p *parser) str(isKey bool) (string, error) {
	d := p.data
	i := p.pos + 1
	start := i
	for i < len(d) {
		c := d[i]
		if c == '"' {
			p.pos = i + 1
			if isKey {
				return p.keys.Intern(d[start:i]), nil
			}
			return string(d[start:i]), nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			p.pos = i
			return "", p.errf("control character in string")
		}
		i++
	}
	if i >= len(d) {
		p.pos = i
		return "", p.errf("unterminated string")
	}
	// Slow path with escapes.
	buf := append(p.buf[:0], d[start:i]...)
	for i < len(d) {
		c := d[i]
		switch {
		case c == '"':
			p.pos = i + 1
			p.buf = buf
			if isKey {
				return p.keys.Intern(buf), nil
			}
			return string(buf), nil
		case c == '\\':
			i++
			if i >= len(d) {
				p.pos = i
				return "", p.errf("unterminated string")
			}
			switch d[i] {
			case '"', '\\', '/':
				buf = append(buf, d[i])
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
				r, ok := hex4(d, i+1)
				if !ok {
					p.pos = i
					return "", p.errf("invalid unicode escape")
				}
				i += 4
				if r >= 0xD800 && r < 0xDC00 && i+6 < len(d)+0 && d[i+1] == '\\' && d[i+2] == 'u' {
					if r2, ok := hex4(d, i+3); ok && r2 >= 0xDC00 && r2 < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
						i += 6
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				p.pos = i
				return "", p.errf("invalid escape")
			}
			i++
		case c < 0x20:
			p.pos = i
			return "", p.errf("control character in string")
		default:
			j := i + 1
			for j < len(d) && d[j] != '"' && d[j] != '\\' && d[j] >= 0x20 {
				j++
			}
			buf = append(buf, d[i:j]...)
			i = j
		}
	}
	p.pos = i
	return "", p.errf("unterminated string")
}

func hex4(d []byte, i int) (rune, bool) {
	if i+4 > len(d) {
		return 0, false
	}
	var r rune
	for _, c := range d[i : i+4] {
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

func (p *parser) array(depth int) (Value, error) {
	p.pos++
	p.skipWS()
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return Array([]Value{}), nil
	}
	items := make([]Value, 0, 4)
	for {
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return Null, err
		}
		items = append(items, v)
		p.skipWS()
		if p.pos >= len(p.data) {
			return Null, p.errf("unterminated array")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return Array(items), nil
		default:
			return Null, p.errf("expected , or ]")
		}
	}
}

func (p *parser) object(depth int) (Value, error) {
	p.pos++
	p.skipWS()
	o := NewObject(4)
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return ObjectValue(o), nil
	}
	for {
		p.skipWS()
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return Null, p.errf("expected object key")
		}
		k, err := p.str(true)
		if err != nil {
			return Null, err
		}
		p.skipWS()
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return Null, p.errf("expected :")
		}
		p.pos++
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return Null, err
		}
		o.Set(k, v)
		p.skipWS()
		if p.pos >= len(p.data) {
			return Null, p.errf("unterminated object")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return ObjectValue(o), nil
		default:
			return Null, p.errf("expected , or }")
		}
	}
}

// ParseNumber parses s as a JSON number literal (and nothing else).
func ParseNumber(s string) (float64, bool) {
	p := parser{data: []byte(s)}
	if len(s) == 0 || (s[0] != '-' && (s[0] < '0' || s[0] > '9')) {
		return 0, false
	}
	v, err := p.number()
	if err != nil || p.pos != len(s) {
		return 0, false
	}
	return v.num, true
}
