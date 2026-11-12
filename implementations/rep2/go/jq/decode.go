package jq

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

// maxDepth bounds nesting while parsing JSON, to keep recursion bounded.
const maxDepth = 10000

// SyntaxError describes malformed JSON input.
type SyntaxError struct {
	Offset int
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("json: %s at offset %d", e.Msg, e.Offset)
}

// ParseJSON parses exactly one JSON value (RFC 8259) from data, allowing
// surrounding whitespace.
func ParseJSON(data []byte) (Value, error) {
	return ParseJSONString(string(data))
}

// ParseJSONString is like ParseJSON for a string. Decoded strings may share
// memory with s.
func ParseJSONString(s string) (Value, error) {
	d := &decoder{s: s}
	d.skipWS()
	v, err := d.value(0)
	if err != nil {
		return nil, err
	}
	d.skipWS()
	if d.pos != len(d.s) {
		return nil, d.fail("unexpected trailing data")
	}
	return v, nil
}

type decoder struct {
	s   string
	pos int
}

func (d *decoder) fail(msg string) error { return &SyntaxError{Offset: d.pos, Msg: msg} }

func (d *decoder) skipWS() {
	for d.pos < len(d.s) {
		switch d.s[d.pos] {
		case ' ', '\t', '\n', '\r':
			d.pos++
		default:
			return
		}
	}
}

func (d *decoder) value(depth int) (Value, error) {
	if d.pos >= len(d.s) {
		return nil, d.fail("unexpected end of input")
	}
	if depth > maxDepth {
		return nil, d.fail("nesting too deep")
	}
	switch c := d.s[d.pos]; {
	case c == '{':
		return d.object(depth)
	case c == '[':
		return d.array(depth)
	case c == '"':
		s, err := d.str()
		if err != nil {
			return nil, err
		}
		return s, nil
	case c == '-' || (c >= '0' && c <= '9'):
		return d.number()
	case d.literal("true"):
		return true, nil
	case d.literal("false"):
		return false, nil
	case d.literal("null"):
		return nil, nil
	}
	return nil, d.fail("invalid character")
}

func (d *decoder) literal(w string) bool {
	if len(d.s)-d.pos >= len(w) && d.s[d.pos:d.pos+len(w)] == w {
		d.pos += len(w)
		return true
	}
	return false
}

func (d *decoder) array(depth int) (Value, error) {
	d.pos++ // [
	arr := []Value{}
	d.skipWS()
	if d.pos < len(d.s) && d.s[d.pos] == ']' {
		d.pos++
		return arr, nil
	}
	for {
		d.skipWS()
		v, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		d.skipWS()
		if d.pos >= len(d.s) {
			return nil, d.fail("unterminated array")
		}
		switch d.s[d.pos] {
		case ',':
			d.pos++
		case ']':
			d.pos++
			return arr, nil
		default:
			return nil, d.fail("expected , or ]")
		}
	}
}

func (d *decoder) object(depth int) (Value, error) {
	d.pos++ // {
	obj := NewObject(4)
	d.skipWS()
	if d.pos < len(d.s) && d.s[d.pos] == '}' {
		d.pos++
		return obj, nil
	}
	for {
		d.skipWS()
		if d.pos >= len(d.s) || d.s[d.pos] != '"' {
			return nil, d.fail("expected object key")
		}
		k, err := d.str()
		if err != nil {
			return nil, err
		}
		d.skipWS()
		if d.pos >= len(d.s) || d.s[d.pos] != ':' {
			return nil, d.fail("expected :")
		}
		d.pos++
		d.skipWS()
		v, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		obj.Set(k, v)
		d.skipWS()
		if d.pos >= len(d.s) {
			return nil, d.fail("unterminated object")
		}
		switch d.s[d.pos] {
		case ',':
			d.pos++
		case '}':
			d.pos++
			return obj, nil
		default:
			return nil, d.fail("expected , or }")
		}
	}
}

// str decodes the string starting at the opening quote.
func (d *decoder) str() (string, error) {
	d.pos++ // opening quote
	start := d.pos
	// Fast path: no escapes.
	for i := start; i < len(d.s); i++ {
		c := d.s[i]
		if c == '"' {
			d.pos = i + 1
			return d.s[start:i], nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			d.pos = i
			return "", d.fail("control character in string")
		}
	}
	buf := make([]byte, 0, 32)
	for d.pos < len(d.s) {
		c := d.s[d.pos]
		switch {
		case c == '"':
			d.pos++
			return string(buf), nil
		case c < 0x20:
			return "", d.fail("control character in string")
		case c != '\\':
			buf = append(buf, c)
			d.pos++
		default:
			d.pos++
			if d.pos >= len(d.s) {
				return "", d.fail("unterminated string")
			}
			e := d.s[d.pos]
			d.pos++
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
				r, err := d.unicodeEscape()
				if err != nil {
					return "", err
				}
				buf = utf8.AppendRune(buf, r)
			default:
				return "", d.fail("invalid escape")
			}
		}
	}
	return "", d.fail("unterminated string")
}

func (d *decoder) hex4() (rune, bool) {
	if d.pos+4 > len(d.s) {
		return 0, false
	}
	var r rune
	for i := 0; i < 4; i++ {
		c := d.s[d.pos+i]
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
	d.pos += 4
	return r, true
}

// unicodeEscape decodes the XXXX after \u, combining surrogate pairs.
func (d *decoder) unicodeEscape() (rune, error) {
	r, ok := d.hex4()
	if !ok {
		return 0, d.fail("invalid \\u escape")
	}
	if r >= 0xD800 && r < 0xDC00 && d.pos+1 < len(d.s) && d.s[d.pos] == '\\' && d.s[d.pos+1] == 'u' {
		save := d.pos
		d.pos += 2
		if lo, ok := d.hex4(); ok && lo >= 0xDC00 && lo < 0xE000 {
			return 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00), nil
		}
		d.pos = save
	}
	return r, nil // lone surrogates become U+FFFD when encoded
}

// scanNumber returns the end of the JSON number starting at s[i], or -1.
func scanNumber(s string, i int) (end int, simpleInt bool) {
	simpleInt = true
	if i < len(s) && s[i] == '-' {
		i++
	}
	if i >= len(s) {
		return -1, false
	}
	switch {
	case s[i] == '0':
		i++
	case s[i] >= '1' && s[i] <= '9':
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
	default:
		return -1, false
	}
	if i < len(s) && s[i] == '.' {
		simpleInt = false
		i++
		j := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == j {
			return -1, false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		simpleInt = false
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		j := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == j {
			return -1, false
		}
	}
	return i, simpleInt
}

func (d *decoder) number() (Value, error) {
	end, simple := scanNumber(d.s, d.pos)
	if end < 0 {
		return nil, d.fail("invalid number")
	}
	text := d.s[d.pos:end]
	d.pos = end
	return numberValue(text, simple), nil
}

// numberValue converts validated JSON number text to a float64.
func numberValue(text string, simpleInt bool) float64 {
	if simpleInt && len(text) <= 15 {
		neg := text[0] == '-'
		var n int64
		for i := 0; i < len(text); i++ {
			if text[i] != '-' {
				n = n*10 + int64(text[i]-'0')
			}
		}
		if neg {
			return -float64(n)
		}
		return float64(n)
	}
	f, _ := strconv.ParseFloat(text, 64) // overflow gives ±Inf, which is acceptable
	return f
}

// parseNumberText parses text that must be entirely one JSON number.
func parseNumberText(text string) (float64, bool) {
	end, simple := scanNumber(text, 0)
	if end != len(text) {
		return 0, false
	}
	return numberValue(text, simple), true
}
