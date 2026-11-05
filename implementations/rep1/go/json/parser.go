package jsoncanon

import "unicode/utf8"

// MaxDepth is the maximum nesting depth of arrays and objects. A top-level
// array or object has depth 1.
const MaxDepth = 512

// Parse validates and parses a complete JSON document.
//
// The returned Value may reference src for strings and numbers, so src must
// not be modified while the Value is in use. The error, if any, is a
// *[SyntaxError].
func Parse(src []byte) (*Value, error) {
	if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF {
		return nil, &SyntaxError{0, "byte-order mark not allowed"}
	}
	if ok, at := validUTF8(src); !ok {
		return nil, &SyntaxError{at, "invalid UTF-8"}
	}
	p := parser{src: src}
	p.skipWS()
	v, err := p.value()
	if err != nil {
		return nil, err
	}
	p.skipWS()
	if p.pos != len(src) {
		return nil, p.fail("unexpected data after value")
	}
	return &v, nil
}

type parser struct {
	src   []byte
	pos   int
	depth int
	// stack is a shared scratch stack of children of the containers
	// currently being parsed. When a container closes, its children are
	// copied out into an exactly sized slice.
	stack []Value
}

func (p *parser) fail(msg string) error { return &SyntaxError{p.pos, msg} }

func (p *parser) skipWS() {
	s, i := p.src, p.pos
	for i < len(s) {
		switch s[i] {
		case ' ', '\t', '\n', '\r':
			i++
			continue
		}
		break
	}
	p.pos = i
}

// value parses one value starting at p.pos (whitespace already skipped).
func (p *parser) value() (Value, error) {
	if p.pos >= len(p.src) {
		return Value{}, p.fail("unexpected end of input")
	}
	switch c := p.src[p.pos]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		p.pos++
		s, err := p.str()
		return Value{kind: String, text: s}, err
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case c == 't':
		return p.literal("true", True)
	case c == 'f':
		return p.literal("false", False)
	case c == 'n':
		return p.literal("null", Null)
	}
	return Value{}, p.fail("unexpected character")
}

func (p *parser) literal(word string, k Kind) (Value, error) {
	if len(p.src)-p.pos < len(word) || string(p.src[p.pos:p.pos+len(word)]) != word {
		return Value{}, p.fail("invalid literal")
	}
	p.pos += len(word)
	return Value{kind: k}, nil
}

func (p *parser) enter() error {
	p.depth++
	if p.depth > MaxDepth {
		return p.fail("nesting too deep")
	}
	return nil
}

func (p *parser) array() (Value, error) {
	if err := p.enter(); err != nil {
		return Value{}, err
	}
	p.pos++ // '['
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == ']' {
		p.pos++
		p.depth--
		return Value{kind: Array}, nil
	}
	base := len(p.stack)
	for {
		p.skipWS()
		v, err := p.value()
		if err != nil {
			return Value{}, err
		}
		p.stack = append(p.stack, v)
		p.skipWS()
		if p.pos >= len(p.src) {
			return Value{}, p.fail("unterminated array")
		}
		c := p.src[p.pos]
		p.pos++
		if c == ',' {
			continue
		}
		if c == ']' {
			break
		}
		p.pos--
		return Value{}, p.fail("expected ',' or ']'")
	}
	p.depth--
	return Value{kind: Array, kids: p.popTo(base)}, nil
}

func (p *parser) object() (Value, error) {
	if err := p.enter(); err != nil {
		return Value{}, err
	}
	p.pos++ // '{'
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		p.depth--
		return Value{kind: Object}, nil
	}
	base := len(p.stack)
	for {
		p.skipWS()
		if p.pos >= len(p.src) || p.src[p.pos] != '"' {
			return Value{}, p.fail("expected string key")
		}
		p.pos++
		key, err := p.str()
		if err != nil {
			return Value{}, err
		}
		p.stack = append(p.stack, Value{kind: String, text: key})
		p.skipWS()
		if p.pos >= len(p.src) || p.src[p.pos] != ':' {
			return Value{}, p.fail("expected ':'")
		}
		p.pos++
		p.skipWS()
		v, err := p.value()
		if err != nil {
			return Value{}, err
		}
		p.stack = append(p.stack, v)
		p.skipWS()
		if p.pos >= len(p.src) {
			return Value{}, p.fail("unterminated object")
		}
		c := p.src[p.pos]
		p.pos++
		if c == ',' {
			continue
		}
		if c == '}' {
			break
		}
		p.pos--
		return Value{}, p.fail("expected ',' or '}'")
	}
	p.depth--
	return Value{kind: Object, kids: p.popTo(base)}, nil
}

// popTo copies the scratch stack above base into a new slice and truncates it.
func (p *parser) popTo(base int) []Value {
	kids := make([]Value, len(p.stack)-base)
	copy(kids, p.stack[base:])
	clear(p.stack[base:])
	p.stack = p.stack[:base]
	return kids
}

// special marks the bytes that end a run of plain string characters.
var special = func() (t [256]bool) {
	for i := 0; i < 0x20; i++ {
		t[i] = true
	}
	t['"'], t['\\'] = true, true
	return
}()

// str parses the remainder of a string whose opening quote has been consumed
// and returns its decoded bytes. Escape-free strings alias the input.
func (p *parser) str() ([]byte, error) {
	s := p.src
	i := p.pos
	start := i
	var buf []byte // allocated at the first escape
	for {
		run := i
		for i < len(s) && !special[s[i]] {
			i++
		}
		if i >= len(s) {
			p.pos = i
			return nil, p.fail("unterminated string")
		}
		c := s[i]
		if c == '"' {
			p.pos = i + 1
			if buf == nil {
				return s[start:i], nil
			}
			return append(buf, s[run:i]...), nil
		}
		if c < 0x20 {
			p.pos = i
			return nil, p.fail("control character in string")
		}
		// Backslash escape.
		if buf == nil {
			buf = make([]byte, 0, i-start+16)
			buf = append(buf, s[start:i]...)
		} else {
			buf = append(buf, s[run:i]...)
		}
		i++
		if i >= len(s) {
			p.pos = i
			return nil, p.fail("unterminated string")
		}
		switch s[i] {
		case '"', '\\', '/':
			buf = append(buf, s[i])
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
			r, ok := hex4(s, i+1)
			i += 4
			if !ok {
				p.pos = i
				return nil, p.fail("invalid \\u escape")
			}
			switch {
			case r >= 0xD800 && r < 0xDC00:
				lo, ok := rune(0), false
				if i+6 < len(s) && s[i+1] == '\\' && s[i+2] == 'u' {
					lo, ok = hex4(s, i+3)
				}
				if !ok || lo < 0xDC00 || lo > 0xDFFF {
					p.pos = i
					return nil, p.fail("unpaired high surrogate")
				}
				r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
				i += 6
			case r >= 0xDC00 && r <= 0xDFFF:
				p.pos = i
				return nil, p.fail("unpaired low surrogate")
			}
			buf = utf8.AppendRune(buf, r)
		default:
			p.pos = i
			return nil, p.fail("invalid escape")
		}
		i++
	}
}

// hex4 decodes four ASCII hex digits at s[at:].
func hex4(s []byte, at int) (rune, bool) {
	if at+4 > len(s) {
		return 0, false
	}
	var r rune
	for _, c := range s[at : at+4] {
		switch {
		case c >= '0' && c <= '9':
			c -= '0'
		case c >= 'a' && c <= 'f':
			c = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			c = c - 'A' + 10
		default:
			return 0, false
		}
		r = r<<4 | rune(c)
	}
	return r, true
}

// number validates a number lexeme and stores its canonical text. Without an
// exponent that is the input slice itself; otherwise the mantissa followed by
// the normalized exponent.
func (p *parser) number() (Value, error) {
	s := p.src
	start, i := p.pos, p.pos
	if s[i] == '-' {
		i++
	}
	if i >= len(s) {
		p.pos = i
		return Value{}, p.fail("invalid number")
	}
	switch {
	case s[i] == '0':
		i++
	case s[i] >= '1' && s[i] <= '9':
		for i < len(s) && isDigit(s[i]) {
			i++
		}
	default:
		p.pos = i
		return Value{}, p.fail("invalid number")
	}
	if i < len(s) && s[i] == '.' {
		i++
		d := i
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		if i == d {
			p.pos = i
			return Value{}, p.fail("digits required after decimal point")
		}
	}
	if i >= len(s) || (s[i] != 'e' && s[i] != 'E') {
		p.pos = i
		return Value{kind: Number, text: s[start:i]}, nil
	}
	mantEnd := i
	i++
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i++
	}
	d := i
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	if i == d {
		p.pos = i
		return Value{}, p.fail("digits required in exponent")
	}
	p.pos = i
	digits := s[d:i]
	for len(digits) > 1 && digits[0] == '0' {
		digits = digits[1:]
	}
	if digits[0] == '0' {
		neg = false
	}
	out := make([]byte, 0, mantEnd-start+2+len(digits))
	out = append(out, s[start:mantEnd]...)
	out = append(out, 'e')
	if neg {
		out = append(out, '-')
	}
	out = append(out, digits...)
	return Value{kind: Number, text: out}, nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
