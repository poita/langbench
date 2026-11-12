package value

import (
	"fmt"
	"math"
	"strconv"
	"unicode/utf8"
)

// maxDepth bounds array/object nesting so hostile input cannot exhaust the
// stack.
const maxDepth = 10000

// SyntaxError describes malformed JSON text.
type SyntaxError struct {
	Offset int // byte offset of the problem
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("invalid JSON at offset %d: %s", e.Offset, e.Msg)
}

// Parse decodes exactly one JSON value (RFC 8259) from data, allowing
// surrounding whitespace.
func Parse(data []byte) (Value, error) {
	d := decoder{data: data}
	d.skipWS()
	v, err := d.value(0)
	if err != nil {
		return nil, err
	}
	d.skipWS()
	if d.pos != len(d.data) {
		return nil, d.errf("unexpected trailing data")
	}
	return v, nil
}

// ParseString is Parse for a string argument.
func ParseString(s string) (Value, error) { return Parse([]byte(s)) }

// ParseNumber converts s to a float64 if s is a complete JSON number
// (optional minus, integer part without leading zeros, optional fraction and
// exponent). The result is the correctly rounded nearest double.
func ParseNumber(s string) (float64, bool) {
	d := decoder{data: []byte(s)}
	end, ok := d.scanNumber(0)
	if !ok || end != len(s) {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil && !isRange(err) {
		return 0, false
	}
	return f, true
}

func isRange(err error) bool {
	ne, ok := err.(*strconv.NumError)
	return ok && ne.Err == strconv.ErrRange
}

type decoder struct {
	data []byte
	pos  int
}

func (d *decoder) errf(format string, a ...any) error {
	return &SyntaxError{Offset: d.pos, Msg: fmt.Sprintf(format, a...)}
}

func (d *decoder) skipWS() {
	for d.pos < len(d.data) {
		switch d.data[d.pos] {
		case ' ', '\t', '\n', '\r':
			d.pos++
		default:
			return
		}
	}
}

func (d *decoder) value(depth int) (Value, error) {
	if d.pos >= len(d.data) {
		return nil, d.errf("unexpected end of input")
	}
	switch c := d.data[d.pos]; {
	case c == '{':
		return d.object(depth + 1)
	case c == '[':
		return d.array(depth + 1)
	case c == '"':
		return d.str()
	case c == 't':
		return d.literal("true", true)
	case c == 'f':
		return d.literal("false", false)
	case c == 'n':
		return d.literal("null", nil)
	case c == '-' || (c >= '0' && c <= '9'):
		return d.number()
	}
	return nil, d.errf("unexpected character %q", d.data[d.pos])
}

func (d *decoder) literal(word string, v Value) (Value, error) {
	if d.pos+len(word) > len(d.data) || string(d.data[d.pos:d.pos+len(word)]) != word {
		return nil, d.errf("invalid literal")
	}
	d.pos += len(word)
	return v, nil
}

// scanNumber validates the number starting at start and returns its end.
func (d *decoder) scanNumber(start int) (int, bool) {
	p, data := start, d.data
	if p < len(data) && data[p] == '-' {
		p++
	}
	if p >= len(data) {
		return 0, false
	}
	switch {
	case data[p] == '0':
		p++
	case data[p] >= '1' && data[p] <= '9':
		for p < len(data) && data[p] >= '0' && data[p] <= '9' {
			p++
		}
	default:
		return 0, false
	}
	if p < len(data) && data[p] == '.' {
		p++
		q := p
		for p < len(data) && data[p] >= '0' && data[p] <= '9' {
			p++
		}
		if p == q {
			return 0, false
		}
	}
	if p < len(data) && (data[p] == 'e' || data[p] == 'E') {
		p++
		if p < len(data) && (data[p] == '+' || data[p] == '-') {
			p++
		}
		q := p
		for p < len(data) && data[p] >= '0' && data[p] <= '9' {
			p++
		}
		if p == q {
			return 0, false
		}
	}
	return p, true
}

func (d *decoder) number() (Value, error) {
	start := d.pos
	end, ok := d.scanNumber(start)
	if !ok {
		return nil, d.errf("invalid number")
	}
	d.pos = end
	text := d.data[start:end]
	// Fast path: short integers are exactly representable.
	if n := len(text); n <= 15 {
		i, neg := 0, false
		if text[0] == '-' {
			i, neg = 1, true
		}
		var acc int64
		simple := i < n
		for ; i < n; i++ {
			c := text[i]
			if c < '0' || c > '9' {
				simple = false
				break
			}
			acc = acc*10 + int64(c-'0')
		}
		if simple {
			if neg {
				if acc == 0 {
					return negZero, nil
				}
				acc = -acc
			}
			return float64(acc), nil
		}
	}
	f, err := strconv.ParseFloat(string(text), 64)
	if err != nil && !isRange(err) {
		return nil, d.errf("invalid number")
	}
	return f, nil
}

var negZero = math.Copysign(0, -1)

func (d *decoder) array(depth int) (Value, error) {
	if depth > maxDepth {
		return nil, d.errf("nesting too deep")
	}
	d.pos++ // [
	arr := []Value{}
	d.skipWS()
	if d.pos < len(d.data) && d.data[d.pos] == ']' {
		d.pos++
		return arr, nil
	}
	for {
		d.skipWS()
		v, err := d.value(depth)
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		d.skipWS()
		if d.pos >= len(d.data) {
			return nil, d.errf("unterminated array")
		}
		switch d.data[d.pos] {
		case ',':
			d.pos++
		case ']':
			d.pos++
			return arr, nil
		default:
			return nil, d.errf("expected ',' or ']'")
		}
	}
}

func (d *decoder) object(depth int) (Value, error) {
	if depth > maxDepth {
		return nil, d.errf("nesting too deep")
	}
	d.pos++ // {
	b := NewBuilder(4)
	d.skipWS()
	if d.pos < len(d.data) && d.data[d.pos] == '}' {
		d.pos++
		return b.Build(), nil
	}
	for {
		d.skipWS()
		if d.pos >= len(d.data) || d.data[d.pos] != '"' {
			return nil, d.errf("expected object key")
		}
		k, err := d.str()
		if err != nil {
			return nil, err
		}
		d.skipWS()
		if d.pos >= len(d.data) || d.data[d.pos] != ':' {
			return nil, d.errf("expected ':'")
		}
		d.pos++
		d.skipWS()
		v, err := d.value(depth)
		if err != nil {
			return nil, err
		}
		b.Set(k.(string), v)
		d.skipWS()
		if d.pos >= len(d.data) {
			return nil, d.errf("unterminated object")
		}
		switch d.data[d.pos] {
		case ',':
			d.pos++
		case '}':
			d.pos++
			return b.Build(), nil
		default:
			return nil, d.errf("expected ',' or '}'")
		}
	}
}

func (d *decoder) str() (Value, error) {
	s, err := d.rawString()
	return s, err
}

func (d *decoder) rawString() (string, error) {
	d.pos++ // opening quote
	start := d.pos
	data := d.data
	// Fast path: no escapes.
	for p := start; p < len(data); p++ {
		c := data[p]
		if c == '"' {
			d.pos = p + 1
			return string(data[start:p]), nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			d.pos = p
			return "", d.errf("control character in string")
		}
	}
	buf := make([]byte, 0, 32)
	p := start
	for p < len(data) {
		c := data[p]
		switch {
		case c == '"':
			d.pos = p + 1
			return string(buf), nil
		case c < 0x20:
			d.pos = p
			return "", d.errf("control character in string")
		case c != '\\':
			buf = append(buf, c)
			p++
			continue
		}
		p++
		if p >= len(data) {
			break
		}
		switch data[p] {
		case '"', '\\', '/':
			buf = append(buf, data[p])
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
			r, ok := hex4(data, p+1)
			if !ok {
				d.pos = p
				return "", d.errf("invalid \\u escape")
			}
			p += 4
			if r >= 0xD800 && r < 0xDC00 && data[p+1] == '\\' && data[p+2] == 'u' {
				if lo, ok := hex4(data, p+3); ok && lo >= 0xDC00 && lo < 0xE000 {
					r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
					p += 6
				}
			}
			if r >= 0xD800 && r < 0xE000 {
				r = utf8.RuneError
			}
			buf = utf8.AppendRune(buf, r)
		default:
			d.pos = p
			return "", d.errf("invalid escape")
		}
		p++
	}
	d.pos = len(data)
	return "", d.errf("unterminated string")
}

func hex4(data []byte, p int) (rune, bool) {
	if p+4 > len(data) {
		return 0, false
	}
	var r rune
	for _, c := range data[p : p+4] {
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
