package jsonvalue

import (
	"fmt"
	"unicode/utf8"
)

// SyntaxError describes malformed JSON input.
type SyntaxError struct {
	Offset int    // byte offset of the problem
	Msg    string // description
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("json: %s at offset %d", e.Msg, e.Offset)
}

// Parse parses exactly one JSON value (RFC 8259) from data. Numbers are kept
// exact. Surrounding whitespace is allowed; anything else after the value is
// an error.
func Parse(data []byte) (Value, error) {
	p := &parser{data: data}
	p.skipSpace()
	v, err := p.value()
	if err != nil {
		return Value{}, err
	}
	p.skipSpace()
	if p.pos != len(p.data) {
		return Value{}, p.errf("unexpected trailing data")
	}
	return v, nil
}

// ParseString is Parse for a string argument.
func ParseString(s string) (Value, error) { return Parse([]byte(s)) }

type parser struct {
	data []byte
	pos  int
}

func (p *parser) errf(format string, args ...any) error {
	return &SyntaxError{Offset: p.pos, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) skipSpace() {
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
	if len(p.data)-p.pos >= len(word) && string(p.data[p.pos:p.pos+len(word)]) == word {
		p.pos += len(word)
		return v, nil
	}
	return Value{}, p.errf("invalid literal")
}

func (p *parser) value() (Value, error) {
	if p.pos >= len(p.data) {
		return Value{}, p.errf("unexpected end of input")
	}
	switch c := p.data[p.pos]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		s, err := p.str()
		if err != nil {
			return Value{}, err
		}
		return NewString(s), nil
	case c == 't':
		return p.literal("true", NewBool(true))
	case c == 'f':
		return p.literal("false", NewBool(false))
	case c == 'n':
		return p.literal("null", Null())
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	default:
		return Value{}, p.errf("unexpected character %q", c)
	}
}

func (p *parser) number() (Value, error) {
	start := p.pos
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {
			p.pos++
			continue
		}
		break
	}
	n, err := ParseNumber(string(p.data[start:p.pos]))
	if err != nil {
		p.pos = start
		return Value{}, p.errf("invalid number")
	}
	return NewNumber(n), nil
}

func (p *parser) array() (Value, error) {
	p.pos++ // [
	var elems []Value
	p.skipSpace()
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return NewArray([]Value{}), nil
	}
	for {
		p.skipSpace()
		v, err := p.value()
		if err != nil {
			return Value{}, err
		}
		elems = append(elems, v)
		p.skipSpace()
		if p.pos >= len(p.data) {
			return Value{}, p.errf("unterminated array")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return NewArray(elems), nil
		default:
			return Value{}, p.errf("expected ',' or ']'")
		}
	}
}

func (p *parser) object() (Value, error) {
	p.pos++ // {
	members := []Member{}
	p.skipSpace()
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return NewObjectValue(NewObject(members)), nil
	}
	for {
		p.skipSpace()
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return Value{}, p.errf("expected string key")
		}
		key, err := p.str()
		if err != nil {
			return Value{}, err
		}
		p.skipSpace()
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return Value{}, p.errf("expected ':'")
		}
		p.pos++
		p.skipSpace()
		v, err := p.value()
		if err != nil {
			return Value{}, err
		}
		members = append(members, Member{key, v})
		p.skipSpace()
		if p.pos >= len(p.data) {
			return Value{}, p.errf("unterminated object")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return NewObjectValue(NewObject(members)), nil
		default:
			return Value{}, p.errf("expected ',' or '}'")
		}
	}
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

func (p *parser) hex4() (rune, bool) {
	if p.pos+4 > len(p.data) {
		return 0, false
	}
	var r rune
	for i := 0; i < 4; i++ {
		h := hexVal(p.data[p.pos+i])
		if h < 0 {
			return 0, false
		}
		r = r<<4 | rune(h)
	}
	p.pos += 4
	return r, true
}

// str parses a string literal starting at the opening quote.
func (p *parser) str() (string, error) {
	p.pos++ // opening quote
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c == '"' {
			s := string(p.data[start:p.pos])
			p.pos++
			return s, nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			return "", p.errf("control character in string")
		}
		p.pos++
	}
	buf := append([]byte(nil), p.data[start:p.pos]...)
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		switch {
		case c == '"':
			p.pos++
			return string(buf), nil
		case c < 0x20:
			return "", p.errf("control character in string")
		case c != '\\':
			buf = append(buf, c)
			p.pos++
			continue
		}
		p.pos++
		if p.pos >= len(p.data) {
			break
		}
		e := p.data[p.pos]
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
			r, ok := p.hex4()
			if !ok {
				return "", p.errf("invalid \\u escape")
			}
			if r >= 0xD800 && r < 0xDC00 && p.pos+1 < len(p.data) && p.data[p.pos] == '\\' && p.data[p.pos+1] == 'u' {
				save := p.pos
				p.pos += 2
				if r2, ok := p.hex4(); ok && r2 >= 0xDC00 && r2 < 0xE000 {
					r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
				} else {
					p.pos = save
				}
			}
			buf = utf8.AppendRune(buf, r) // lone surrogates become U+FFFD
		default:
			return "", p.errf("invalid escape")
		}
	}
	return "", p.errf("unterminated string")
}
