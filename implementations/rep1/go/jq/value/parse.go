package value

import (
	"fmt"
	"strconv"
)

// maxDepth bounds container nesting so hostile input cannot exhaust the stack.
const maxDepth = 10000

// SyntaxError describes malformed JSON text.
type SyntaxError struct {
	Offset int
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("invalid JSON at offset %d: %s", e.Offset, e.Msg)
}

type jsonParser struct {
	s     string
	pos   int
	depth int
	keys  map[string]string // interned object keys
}

// Parse parses exactly one JSON value (RFC 8259) from s, allowing
// surrounding whitespace. Strings without escapes share memory with s, and
// object keys are interned so a repeated key is stored once.
func Parse(s string) (Value, error) {
	p := &jsonParser{s: s, keys: make(map[string]string)}
	p.skipWS()
	v, err := p.value()
	if err != nil {
		return Null, err
	}
	p.skipWS()
	if p.pos != len(p.s) {
		return Null, p.fail("unexpected trailing data")
	}
	return v, nil
}

func (p *jsonParser) fail(msg string) error { return &SyntaxError{p.pos, msg} }

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

func (p *jsonParser) value() (Value, error) {
	if p.pos >= len(p.s) {
		return Null, p.fail("unexpected end of input")
	}
	switch c := p.s[p.pos]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		s, err := p.str()
		return String(s), err
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case p.lit("true"):
		return True, nil
	case p.lit("false"):
		return False, nil
	case p.lit("null"):
		return Null, nil
	}
	return Null, p.fail("unexpected character")
}

func (p *jsonParser) lit(word string) bool {
	if len(p.s)-p.pos >= len(word) && p.s[p.pos:p.pos+len(word)] == word {
		p.pos += len(word)
		return true
	}
	return false
}

func (p *jsonParser) str() (string, error) {
	end, escaped, err := ScanString(p.s, p.pos)
	if err != nil {
		return "", p.fail(err.Error())
	}
	body := p.s[p.pos+1 : end-1]
	if escaped {
		body, err = Unquote(body)
		if err != nil {
			return "", p.fail(err.Error())
		}
	}
	p.pos = end
	return body, nil
}

func (p *jsonParser) array() (Value, error) {
	p.depth++
	if p.depth > maxDepth {
		return Null, p.fail("nesting too deep")
	}
	p.pos++
	p.skipWS()
	var elems []Value
	if p.pos < len(p.s) && p.s[p.pos] == ']' {
		p.pos++
		p.depth--
		return Array([]Value{}), nil
	}
	for {
		p.skipWS()
		v, err := p.value()
		if err != nil {
			return Null, err
		}
		elems = append(elems, v)
		p.skipWS()
		if p.pos >= len(p.s) {
			return Null, p.fail("unterminated array")
		}
		c := p.s[p.pos]
		p.pos++
		if c == ']' {
			break
		}
		if c != ',' {
			p.pos--
			return Null, p.fail("expected ',' or ']'")
		}
	}
	p.depth--
	return Array(elems), nil
}

func (p *jsonParser) object() (Value, error) {
	p.depth++
	if p.depth > maxDepth {
		return Null, p.fail("nesting too deep")
	}
	p.pos++
	p.skipWS()
	b := NewObjectBuilder(4)
	if p.pos < len(p.s) && p.s[p.pos] == '}' {
		p.pos++
		p.depth--
		return b.Build(), nil
	}
	for {
		p.skipWS()
		if p.pos >= len(p.s) || p.s[p.pos] != '"' {
			return Null, p.fail("expected object key")
		}
		k, err := p.str()
		if err != nil {
			return Null, err
		}
		if ik, ok := p.keys[k]; ok {
			k = ik
		} else {
			p.keys[k] = k
		}
		p.skipWS()
		if p.pos >= len(p.s) || p.s[p.pos] != ':' {
			return Null, p.fail("expected ':'")
		}
		p.pos++
		p.skipWS()
		v, err := p.value()
		if err != nil {
			return Null, err
		}
		b.Set(k, v)
		p.skipWS()
		if p.pos >= len(p.s) {
			return Null, p.fail("unterminated object")
		}
		c := p.s[p.pos]
		p.pos++
		if c == '}' {
			break
		}
		if c != ',' {
			p.pos--
			return Null, p.fail("expected ',' or '}'")
		}
	}
	p.depth--
	return b.Build(), nil
}

var pow10 = [...]float64{1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10,
	1e11, 1e12, 1e13, 1e14, 1e15}

func (p *jsonParser) number() (Value, error) {
	end, err := scanNumber(p.s, p.pos)
	if err != nil {
		return Null, p.fail(err.Error())
	}
	f, err := ParseNumber(p.s[p.pos:end])
	if err != nil {
		return Null, p.fail(err.Error())
	}
	p.pos = end
	return Number(f), nil
}

// scanNumber returns the end of the JSON number starting at s[i].
func scanNumber(s string, i int) (int, error) {
	if i < len(s) && s[i] == '-' {
		i++
	}
	digits := func() int {
		n := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
			n++
		}
		return n
	}
	if i < len(s) && s[i] == '0' {
		i++
	} else if digits() == 0 {
		return 0, fmt.Errorf("invalid number")
	}
	if i < len(s) && s[i] == '.' {
		i++
		if digits() == 0 {
			return 0, fmt.Errorf("invalid number")
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return 0, fmt.Errorf("invalid number")
		}
	}
	return i, nil
}

// ParseNumber converts the text of a JSON number to the nearest double. The
// whole string must be a number in JSON syntax.
func ParseNumber(s string) (float64, error) {
	end, err := scanNumber(s, 0)
	if err != nil || end != len(s) {
		return 0, fmt.Errorf("invalid number %q", s)
	}
	// Fast path: at most 15 significant digits and no exponent. The integer
	// mantissa and the power of ten are both exact doubles, so one division
	// is correctly rounded.
	i, neg := 0, false
	if s[0] == '-' {
		neg = true
		i = 1
	}
	var mant int64
	nd, frac := 0, -1
	for ; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			mant = mant*10 + int64(c-'0')
			nd++
			if frac >= 0 {
				frac++
			}
		} else if c == '.' {
			frac = 0
		} else {
			nd = 100 // exponent: take the slow path
			break
		}
	}
	if nd <= 15 {
		f := float64(mant)
		if frac > 0 {
			f /= pow10[frac]
		}
		if neg {
			f = -f
		}
		return f, nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil && !isRangeErr(err) {
		return 0, err
	}
	return f, nil
}

func isRangeErr(err error) bool {
	ne, ok := err.(*strconv.NumError)
	return ok && ne.Err == strconv.ErrRange
}
