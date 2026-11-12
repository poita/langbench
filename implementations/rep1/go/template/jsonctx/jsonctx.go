// Package jsonctx parses a JSON document into template values.
//
// It exists (instead of encoding/json) because the engine needs object
// members in document order and needs to tell integers from floats: a number
// with no fraction and no exponent is an integer, any other number a float.
package jsonctx

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"example.com/template/value"
)

// maxDepth bounds the nesting of arrays and objects.
const maxDepth = 10000

// Parse parses a JSON document whose top-level value must be an object and
// returns it as a dict.
func Parse(text string) (*value.Dict, error) {
	v, err := ParseValue(text)
	if err != nil {
		return nil, err
	}
	d, ok := v.(*value.Dict)
	if !ok {
		return nil, fmt.Errorf("jsonctx: top-level value is not an object")
	}
	return d, nil
}

// ParseValue parses any JSON document.
func ParseValue(text string) (value.Value, error) {
	p := &parser{s: text}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return nil, err
	}
	p.skipWS()
	if p.pos != len(p.s) {
		return nil, p.errorf("unexpected trailing data")
	}
	return v, nil
}

type parser struct {
	s   string
	pos int
}

func (p *parser) errorf(format string, args ...any) error {
	return fmt.Errorf("jsonctx: offset %d: %s", p.pos, fmt.Sprintf(format, args...))
}

func (p *parser) skipWS() {
	for p.pos < len(p.s) {
		switch p.s[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) value(depth int) (value.Value, error) {
	if p.pos >= len(p.s) {
		return nil, p.errorf("unexpected end of input")
	}
	if depth > maxDepth {
		return nil, p.errorf("nesting too deep")
	}
	switch c := p.s[p.pos]; {
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '"':
		return p.str()
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case strings.HasPrefix(p.s[p.pos:], "true"):
		p.pos += 4
		return true, nil
	case strings.HasPrefix(p.s[p.pos:], "false"):
		p.pos += 5
		return false, nil
	case strings.HasPrefix(p.s[p.pos:], "null"):
		p.pos += 4
		return value.None, nil
	}
	return nil, p.errorf("unexpected character %q", p.s[p.pos])
}

func (p *parser) object(depth int) (value.Value, error) {
	p.pos++ // {
	d := value.NewDict(0)
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
		d.Set(k.(string), v)
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

func (p *parser) array(depth int) (value.Value, error) {
	p.pos++ // [
	var items []value.Value
	p.skipWS()
	if p.pos < len(p.s) && p.s[p.pos] == ']' {
		p.pos++
		return value.NewList([]value.Value{}), nil
	}
	for {
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return nil, err
		}
		items = append(items, v)
		p.skipWS()
		if p.pos >= len(p.s) {
			return nil, p.errorf("unterminated array")
		}
		switch p.s[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return value.NewList(items), nil
		default:
			return nil, p.errorf("expected ',' or ']'")
		}
	}
}

func (p *parser) number() (value.Value, error) {
	start := p.pos
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
	isFloat := false
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
	text := p.s[start:p.pos]
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

func (p *parser) str() (value.Value, error) {
	p.pos++ // opening quote
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if c == '"' {
			s := p.s[start:p.pos]
			p.pos++
			return s, nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			return nil, p.errorf("control character in string")
		}
		p.pos++
	}
	var b strings.Builder
	b.WriteString(p.s[start:p.pos])
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		switch {
		case c == '"':
			p.pos++
			return b.String(), nil
		case c < 0x20:
			return nil, p.errorf("control character in string")
		case c != '\\':
			b.WriteByte(c)
			p.pos++
			continue
		}
		p.pos++
		if p.pos >= len(p.s) {
			break
		}
		e := p.s[p.pos]
		p.pos++
		switch e {
		case '"', '\\', '/':
			b.WriteByte(e)
		case 'b':
			b.WriteByte('\b')
		case 'f':
			b.WriteByte('\f')
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case 'u':
			r, err := p.hex4()
			if err != nil {
				return nil, err
			}
			if utf16.IsSurrogate(r) && strings.HasPrefix(p.s[p.pos:], `\u`) {
				save := p.pos
				p.pos += 2
				r2, err := p.hex4()
				if err == nil {
					if dec := utf16.DecodeRune(r, r2); dec != utf8.RuneError {
						r = dec
					} else {
						p.pos = save
					}
				} else {
					p.pos = save
				}
			}
			b.WriteRune(r)
		default:
			return nil, p.errorf("invalid escape \\%c", e)
		}
	}
	return nil, p.errorf("unterminated string")
}

func (p *parser) hex4() (rune, error) {
	if p.pos+4 > len(p.s) {
		return 0, p.errorf("truncated \\u escape")
	}
	n, err := strconv.ParseUint(p.s[p.pos:p.pos+4], 16, 32)
	if err != nil {
		return 0, p.errorf("invalid \\u escape")
	}
	p.pos += 4
	return rune(n), nil
}
