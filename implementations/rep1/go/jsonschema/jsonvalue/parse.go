package jsonvalue

import (
	"unicode/utf8"
)

// Parse parses exactly one JSON value from data, which must be UTF-8 encoded
// RFC 8259 text. Surrounding whitespace is allowed; anything else after the
// value is an error. Numbers are kept exact, and duplicate object keys are
// rejected.
func Parse(data []byte) (Value, error) {
	p := &parser{src: string(data)}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return Value{}, err
	}
	p.skipWS()
	if p.pos != len(p.src) {
		return Value{}, p.errf("unexpected trailing data")
	}
	return v, nil
}

// ParseString is like Parse but takes a string.
func ParseString(s string) (Value, error) { return Parse([]byte(s)) }

// maxDepth bounds nesting so that hostile input cannot exhaust memory.
const maxDepth = 100000

type parser struct {
	src string
	pos int
}

func (p *parser) errf(msg string) error { return &SyntaxError{Msg: msg, Offset: p.pos} }

func (p *parser) skipWS() {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) value(depth int) (Value, error) {
	if depth > maxDepth {
		return Value{}, p.errf("nesting too deep")
	}
	if p.pos >= len(p.src) {
		return Value{}, p.errf("unexpected end of input")
	}
	switch c := p.src[p.pos]; {
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '"':
		s, err := p.str()
		if err != nil {
			return Value{}, err
		}
		return StringValue(s), nil
	case c == '-' || (c >= '0' && c <= '9'):
		n, rest, serr := scanNumber(p.src[p.pos:])
		if serr != nil {
			serr.Offset = p.pos
			return Value{}, serr
		}
		p.pos = len(p.src) - len(rest)
		return NumberValue(n), nil
	case c == 't':
		return p.literal("true", BoolValue(true))
	case c == 'f':
		return p.literal("false", BoolValue(false))
	case c == 'n':
		return p.literal("null", Value{})
	}
	return Value{}, p.errf("unexpected character")
}

func (p *parser) literal(word string, v Value) (Value, error) {
	if len(p.src)-p.pos >= len(word) && p.src[p.pos:p.pos+len(word)] == word {
		p.pos += len(word)
		return v, nil
	}
	return Value{}, p.errf("invalid literal")
}

func (p *parser) array(depth int) (Value, error) {
	p.pos++ // [
	elems := []Value{}
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == ']' {
		p.pos++
		return ArrayValue(elems), nil
	}
	for {
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return Value{}, err
		}
		elems = append(elems, v)
		p.skipWS()
		if p.pos >= len(p.src) {
			return Value{}, p.errf("unterminated array")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return ArrayValue(elems), nil
		default:
			return Value{}, p.errf("expected ',' or ']'")
		}
	}
}

func (p *parser) object(depth int) (Value, error) {
	p.pos++ // {
	keys := []string{}
	vals := []Value{}
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		return ObjectValue(keys, vals), nil
	}
	var seen map[string]struct{}
	for {
		p.skipWS()
		if p.pos >= len(p.src) || p.src[p.pos] != '"' {
			return Value{}, p.errf("expected object key")
		}
		keyPos := p.pos
		k, err := p.str()
		if err != nil {
			return Value{}, err
		}
		if len(keys) >= linearLookupMax {
			if seen == nil {
				seen = make(map[string]struct{}, 2*linearLookupMax)
				for _, e := range keys {
					seen[e] = struct{}{}
				}
			}
			if _, dup := seen[k]; dup {
				p.pos = keyPos
				return Value{}, p.errf("duplicate object key " + quote(k))
			}
			seen[k] = struct{}{}
		} else {
			for _, e := range keys {
				if e == k {
					p.pos = keyPos
					return Value{}, p.errf("duplicate object key " + quote(k))
				}
			}
		}
		p.skipWS()
		if p.pos >= len(p.src) || p.src[p.pos] != ':' {
			return Value{}, p.errf("expected ':'")
		}
		p.pos++
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return Value{}, err
		}
		keys = append(keys, k)
		vals = append(vals, v)
		p.skipWS()
		if p.pos >= len(p.src) {
			return Value{}, p.errf("unterminated object")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return ObjectValue(keys, vals), nil
		default:
			return Value{}, p.errf("expected ',' or '}'")
		}
	}
}

// str parses a string literal starting at the opening quote.
func (p *parser) str() (string, error) {
	p.pos++ // opening quote
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == '"' {
			s := p.src[start:p.pos]
			if !utf8.ValidString(s) {
				return "", p.errf("invalid UTF-8 in string")
			}
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
	buf := append([]byte(nil), p.src[start:p.pos]...)
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		switch {
		case c == '"':
			p.pos++
			if !utf8.Valid(buf) {
				return "", p.errf("invalid UTF-8 in string")
			}
			return string(buf), nil
		case c < 0x20:
			return "", p.errf("control character in string")
		case c != '\\':
			buf = append(buf, c)
			p.pos++
		default:
			p.pos++
			if p.pos >= len(p.src) {
				return "", p.errf("unterminated string")
			}
			e := p.src[p.pos]
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
				if r >= 0xD800 && r < 0xDC00 {
					// High surrogate: must be followed by a low surrogate.
					if p.pos+1 < len(p.src) && p.src[p.pos] == '\\' && p.src[p.pos+1] == 'u' {
						save := p.pos
						p.pos += 2
						r2, ok := p.hex4()
						if ok && r2 >= 0xDC00 && r2 < 0xE000 {
							r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
						} else {
							p.pos = save
							return "", p.errf("unpaired surrogate")
						}
					} else {
						return "", p.errf("unpaired surrogate")
					}
				} else if r >= 0xDC00 && r < 0xE000 {
					return "", p.errf("unpaired surrogate")
				}
				buf = utf8.AppendRune(buf, r)
			default:
				p.pos--
				return "", p.errf("invalid escape")
			}
		}
	}
	return "", p.errf("unterminated string")
}

func (p *parser) hex4() (rune, bool) {
	if p.pos+4 > len(p.src) {
		return 0, false
	}
	var r rune
	for i := 0; i < 4; i++ {
		c := p.src[p.pos+i]
		var d rune
		switch {
		case c >= '0' && c <= '9':
			d = rune(c - '0')
		case c >= 'a' && c <= 'f':
			d = rune(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = rune(c-'A') + 10
		default:
			return 0, false
		}
		r = r<<4 | d
	}
	p.pos += 4
	return r, true
}
