// Package jsonio implements a JSON parser and a compact JSON serialiser for
// the value package. It does not use encoding/json.
package jsonio

import (
	"fmt"
	"strconv"
	"unicode/utf8"

	"example.com/jq/value"
)

// SyntaxError describes malformed JSON input.
type SyntaxError struct {
	Offset int
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("invalid JSON at offset %d: %s", e.Offset, e.Msg)
}

// Parse parses exactly one JSON value surrounded by optional whitespace.
func Parse(data []byte) (value.Value, error) { return ParseString(string(data)) }

// ParseString is like Parse for a string. The returned value may share
// memory with s.
func ParseString(s string) (value.Value, error) {
	p := &parser{s: s, keys: make(map[string]string)}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return value.Null, err
	}
	p.skipWS()
	if p.i != len(p.s) {
		return value.Null, p.fail("unexpected trailing data")
	}
	return v, nil
}

const maxDepth = 10000

type parser struct {
	s     string
	i     int
	keys  map[string]string // interned object keys
	vals  []value.Value     // scratch stack for array elements
	ents  []value.Entry     // scratch stack for object members
	depth int
}

func (p *parser) fail(msg string) error { return &SyntaxError{p.i, msg} }

func (p *parser) skipWS() {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *parser) value(depth int) (value.Value, error) {
	if p.i >= len(p.s) {
		return value.Null, p.fail("unexpected end of input")
	}
	switch c := p.s[p.i]; {
	case c == '"':
		s, err := p.str()
		return value.String(s), err
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case c == 't':
		return p.literal("true", value.True)
	case c == 'f':
		return p.literal("false", value.False)
	case c == 'n':
		return p.literal("null", value.Null)
	}
	return value.Null, p.fail("unexpected character")
}

func (p *parser) literal(word string, v value.Value) (value.Value, error) {
	if len(p.s)-p.i >= len(word) && p.s[p.i:p.i+len(word)] == word {
		p.i += len(word)
		return v, nil
	}
	return value.Null, p.fail("invalid literal")
}

func (p *parser) number() (value.Value, error) {
	start := p.i
	s := p.s
	i := p.i
	neg := false
	if s[i] == '-' {
		neg = true
		i++
	}
	ds := i
	var n uint64
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		n = n*10 + uint64(s[i]-'0')
		i++
	}
	nd := i - ds
	if nd == 0 {
		p.i = i
		return value.Null, p.fail("invalid number")
	}
	if nd > 1 && s[ds] == '0' {
		p.i = i
		return value.Null, p.fail("leading zero in number")
	}
	simple := true
	if i < len(s) && s[i] == '.' {
		simple = false
		i++
		fs := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == fs {
			p.i = i
			return value.Null, p.fail("invalid number")
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		simple = false
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		es := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == es {
			p.i = i
			return value.Null, p.fail("invalid number")
		}
	}
	p.i = i
	if simple && nd <= 15 {
		f := float64(n)
		if neg {
			f = -f
		}
		return value.Number(f), nil
	}
	f, err := strconv.ParseFloat(s[start:i], 64)
	if err != nil && f == 0 { // overflow yields ±Inf with a range error; keep that
		p.i = start
		return value.Null, p.fail("invalid number")
	}
	return value.Number(f), nil
}

// str parses a string literal starting at the opening quote.
func (p *parser) str() (string, error) {
	s := p.s
	i := p.i + 1
	start := i
	for i < len(s) {
		c := s[i]
		if c == '"' {
			p.i = i + 1
			return s[start:i], nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			p.i = i
			return "", p.fail("control character in string")
		}
		i++
	}
	if i >= len(s) {
		p.i = i
		return "", p.fail("unterminated string")
	}
	// Slow path: the string contains escapes.
	buf := make([]byte, 0, i-start+16)
	buf = append(buf, s[start:i]...)
	for i < len(s) {
		c := s[i]
		switch {
		case c == '"':
			p.i = i + 1
			return string(buf), nil
		case c < 0x20:
			p.i = i
			return "", p.fail("control character in string")
		case c != '\\':
			j := i
			for j < len(s) && s[j] != '"' && s[j] != '\\' && s[j] >= 0x20 {
				j++
			}
			buf = append(buf, s[i:j]...)
			i = j
			continue
		}
		i++
		if i >= len(s) {
			break
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
			if !ok {
				p.i = i
				return "", p.fail("invalid \\u escape")
			}
			i += 4
			if r >= 0xD800 && r < 0xDC00 && i+6 < len(s) && s[i+1] == '\\' && s[i+2] == 'u' {
				if r2, ok := hex4(s, i+3); ok && r2 >= 0xDC00 && r2 < 0xE000 {
					r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
					i += 6
				}
			}
			if r >= 0xD800 && r < 0xE000 {
				r = utf8.RuneError
			}
			buf = utf8.AppendRune(buf, r)
		default:
			p.i = i
			return "", p.fail("invalid escape")
		}
		i++
	}
	p.i = i
	return "", p.fail("unterminated string")
}

func hex4(s string, i int) (rune, bool) {
	if i+4 > len(s) {
		return 0, false
	}
	var r rune
	for _, c := range []byte(s[i : i+4]) {
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

func (p *parser) array(depth int) (value.Value, error) {
	if depth >= maxDepth {
		return value.Null, p.fail("nesting too deep")
	}
	p.i++ // [
	base := len(p.vals)
	p.skipWS()
	if p.i < len(p.s) && p.s[p.i] == ']' {
		p.i++
		return value.Array([]value.Value{}), nil
	}
	for {
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return value.Null, err
		}
		p.vals = append(p.vals, v)
		p.skipWS()
		if p.i >= len(p.s) {
			return value.Null, p.fail("unterminated array")
		}
		c := p.s[p.i]
		p.i++
		if c == ',' {
			continue
		}
		if c == ']' {
			break
		}
		p.i--
		return value.Null, p.fail("expected ',' or ']'")
	}
	out := make([]value.Value, len(p.vals)-base)
	copy(out, p.vals[base:])
	clear(p.vals[base:])
	p.vals = p.vals[:base]
	return value.Array(out), nil
}

func (p *parser) object(depth int) (value.Value, error) {
	if depth >= maxDepth {
		return value.Null, p.fail("nesting too deep")
	}
	p.i++ // {
	base := len(p.ents)
	p.skipWS()
	if p.i < len(p.s) && p.s[p.i] == '}' {
		p.i++
		return value.ObjectValue(value.NewObject(0)), nil
	}
	for {
		p.skipWS()
		if p.i >= len(p.s) || p.s[p.i] != '"' {
			return value.Null, p.fail("expected string key")
		}
		k, err := p.str()
		if err != nil {
			return value.Null, err
		}
		if ik, ok := p.keys[k]; ok {
			k = ik
		} else {
			p.keys[k] = k
		}
		p.skipWS()
		if p.i >= len(p.s) || p.s[p.i] != ':' {
			return value.Null, p.fail("expected ':'")
		}
		p.i++
		p.skipWS()
		v, err := p.value(depth + 1)
		if err != nil {
			return value.Null, err
		}
		p.ents = append(p.ents, value.Entry{Key: k, Val: v})
		p.skipWS()
		if p.i >= len(p.s) {
			return value.Null, p.fail("unterminated object")
		}
		c := p.s[p.i]
		p.i++
		if c == ',' {
			continue
		}
		if c == '}' {
			break
		}
		p.i--
		return value.Null, p.fail("expected ',' or '}'")
	}
	o := value.ObjectFromEntries(p.ents[base:])
	clear(p.ents[base:])
	p.ents = p.ents[:base]
	return value.ObjectValue(o), nil
}
