package protowire

import (
	"errors"
	"fmt"
	"strconv"
	"unicode/utf8"
)

// ErrText is wrapped by every error returned from [MessageDesc.ParseText].
var ErrText = errors.New("protowire: invalid text form")

const hexDigits = "0123456789abcdef"

// String returns the canonical text form of m, for example
//
//	{a: 1, b: "x", c: [1, 2], d: {v: -5}}
func (m *Message) String() string { return string(m.AppendText(nil)) }

// AppendText appends the canonical text form of m to dst. Fields appear in
// increasing field-number order; defaults and empty lists are omitted, but a
// present singular message field is always printed. The cost is linear in the
// size of the output.
func (m *Message) AppendText(dst []byte) []byte {
	dst = append(dst, '{')
	first := true
	for i, f := range m.desc.Fields {
		s := &m.slots[i]
		switch {
		case f.Repeated:
			if len(s.list) == 0 {
				continue
			}
		case f.Kind == KindMessage:
			if !s.set {
				continue
			}
		case f.Kind == KindString || f.Kind == KindBytes:
			if len(s.v.b) == 0 {
				continue
			}
		default:
			if s.v.num == 0 {
				continue
			}
		}
		if !first {
			dst = append(dst, ',', ' ')
		}
		first = false
		dst = append(dst, f.Name...)
		dst = append(dst, ':', ' ')
		if f.Repeated {
			dst = append(dst, '[')
			for j, v := range s.list {
				if j > 0 {
					dst = append(dst, ',', ' ')
				}
				dst = appendValueText(dst, f, v)
			}
			dst = append(dst, ']')
		} else {
			dst = appendValueText(dst, f, s.v)
		}
	}
	return append(dst, '}')
}

func appendValueText(dst []byte, f *Field, v value) []byte {
	switch f.Kind {
	case KindMessage:
		return v.msg.AppendText(dst)
	case KindBool:
		if v.num != 0 {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case KindString:
		return appendQuoted(dst, v.b)
	case KindBytes:
		dst = append(dst, 'x', '"')
		for _, c := range v.b {
			dst = append(dst, hexDigits[c>>4], hexDigits[c&15])
		}
		return append(dst, '"')
	}
	if f.Kind.isSigned() {
		return strconv.AppendInt(dst, int64(v.num), 10)
	}
	return strconv.AppendUint(dst, v.num, 10)
}

func appendQuoted(dst, s []byte) []byte {
	dst = append(dst, '"')
	for _, c := range s {
		switch {
		case c == '"':
			dst = append(dst, '\\', '"')
		case c == '\\':
			dst = append(dst, '\\', '\\')
		case c == '\n':
			dst = append(dst, '\\', 'n')
		case c == '\r':
			dst = append(dst, '\\', 'r')
		case c == '\t':
			dst = append(dst, '\\', 't')
		case c < 0x20 || c == 0x7f:
			dst = append(dst, '\\', 'x', hexDigits[c>>4], hexDigits[c&15])
		default:
			dst = append(dst, c)
		}
	}
	return append(dst, '"')
}

// ParseText parses the text form of a message of type d. It accepts the
// canonical form plus: arbitrary runs of spaces between tokens, fields in any
// order, explicit default values, and the string escapes \" \\ \n \r \t and
// \xHH. Unknown or repeated field names, values of the wrong kind,
// out-of-range integers, invalid UTF-8 in strings and trailing text are
// errors wrapping [ErrText].
func (d *MessageDesc) ParseText(text []byte) (*Message, error) {
	p := textParser{s: text}
	m, err := p.parseMessage(d, 0)
	if err != nil {
		return nil, err
	}
	p.skipSpaces()
	if p.pos != len(p.s) {
		return nil, p.errorf("unexpected trailing text")
	}
	return m, nil
}

type textParser struct {
	s   []byte
	pos int
}

func (p *textParser) errorf(format string, args ...any) error {
	return fmt.Errorf("%w: %s at offset %d", ErrText, fmt.Sprintf(format, args...), p.pos)
}

func (p *textParser) skipSpaces() {
	for p.pos < len(p.s) && p.s[p.pos] == ' ' {
		p.pos++
	}
}

// accept consumes c if it is next.
func (p *textParser) accept(c byte) bool {
	if p.pos < len(p.s) && p.s[p.pos] == c {
		p.pos++
		return true
	}
	return false
}

func (p *textParser) parseMessage(d *MessageDesc, depth int) (*Message, error) {
	if depth > MaxDepth {
		return nil, p.errorf("nesting too deep")
	}
	p.skipSpaces()
	if !p.accept('{') {
		return nil, p.errorf("expected '{'")
	}
	m := newMessage(d)
	p.skipSpaces()
	if p.accept('}') {
		return m, nil
	}
	for {
		start := p.pos
		for p.pos < len(p.s) && isTokenByte(p.s[p.pos]) {
			p.pos++
		}
		f := d.byName[string(p.s[start:p.pos])]
		if f == nil {
			p.pos = start
			return nil, p.errorf("unknown field name")
		}
		s := &m.slots[f.index]
		if s.set {
			p.pos = start
			return nil, p.errorf("duplicate field %q", f.Name)
		}
		s.set = true
		p.skipSpaces()
		if !p.accept(':') {
			return nil, p.errorf("expected ':'")
		}
		p.skipSpaces()
		var err error
		if f.Repeated {
			s.list, err = p.parseList(f, depth)
		} else {
			s.v, err = p.parseValue(f, depth)
		}
		if err != nil {
			return nil, err
		}
		p.skipSpaces()
		if p.accept('}') {
			return m, nil
		}
		if !p.accept(',') {
			return nil, p.errorf("expected ',' or '}'")
		}
		p.skipSpaces()
	}
}

func (p *textParser) parseList(f *Field, depth int) ([]value, error) {
	if !p.accept('[') {
		return nil, p.errorf("expected '[' for repeated field %q", f.Name)
	}
	var list []value
	p.skipSpaces()
	if p.accept(']') {
		return list, nil
	}
	for {
		p.skipSpaces()
		v, err := p.parseValue(f, depth)
		if err != nil {
			return nil, err
		}
		list = append(list, v)
		p.skipSpaces()
		if p.accept(']') {
			return list, nil
		}
		if !p.accept(',') {
			return nil, p.errorf("expected ',' or ']'")
		}
	}
}

func (p *textParser) parseValue(f *Field, depth int) (value, error) {
	switch f.Kind {
	case KindMessage:
		m, err := p.parseMessage(f.Message, depth+1)
		return value{msg: m}, err
	case KindString:
		b, err := p.parseString()
		if err == nil && !utf8.Valid(b) {
			err = p.errorf("string is not valid UTF-8")
		}
		return value{b: b}, err
	case KindBytes:
		b, err := p.parseBytes()
		return value{b: b}, err
	case KindBool:
		start := p.pos
		for p.pos < len(p.s) && isTokenByte(p.s[p.pos]) {
			p.pos++
		}
		switch string(p.s[start:p.pos]) {
		case "true":
			return value{num: 1}, nil
		case "false":
			return value{}, nil
		}
		p.pos = start
		return value{}, p.errorf("expected true or false")
	}
	n, err := p.parseInt(f.Kind)
	return value{num: n}, err
}

// parseInt parses a decimal integer and range-checks it for kind k. The
// result is in stored form (signed kinds sign-extended).
func (p *textParser) parseInt(k Kind) (uint64, error) {
	start := p.pos
	neg := p.accept('-')
	ds := p.pos
	var mag uint64
	for p.pos < len(p.s) && p.s[p.pos] >= '0' && p.s[p.pos] <= '9' {
		d := uint64(p.s[p.pos] - '0')
		if mag > (1<<64-1-d)/10 {
			p.pos = start
			return 0, p.errorf("integer out of range")
		}
		mag = mag*10 + d
		p.pos++
	}
	switch {
	case p.pos == ds:
		p.pos = start
		return 0, p.errorf("expected integer")
	case p.s[ds] == '0' && p.pos-ds > 1:
		p.pos = start
		return 0, p.errorf("leading zero")
	case neg && mag == 0:
		p.pos = start
		return 0, p.errorf("negative zero")
	}
	var limit uint64 // largest allowed magnitude
	switch {
	case !k.isSigned() && neg:
		p.pos = start
		return 0, p.errorf("negative value for unsigned type %s", k)
	case k == KindUint32 || k == KindFixed32:
		limit = 1<<32 - 1
	case k == KindUint64 || k == KindFixed64:
		limit = 1<<64 - 1
	case k == KindInt32 || k == KindSint32 || k == KindSfixed32:
		limit = 1<<31 - 1
		if neg {
			limit++
		}
	default:
		limit = 1<<63 - 1
		if neg {
			limit++
		}
	}
	if mag > limit {
		p.pos = start
		return 0, p.errorf("integer out of range for %s", k)
	}
	if neg {
		return -mag, nil
	}
	return mag, nil
}

func hexVal(c byte, upper bool) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case upper && c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

func (p *textParser) parseBytes() ([]byte, error) {
	if !p.accept('x') || !p.accept('"') {
		return nil, p.errorf("expected bytes literal x\"...\"")
	}
	start := p.pos
	for p.pos < len(p.s) && p.s[p.pos] != '"' {
		p.pos++
	}
	if p.pos >= len(p.s) {
		return nil, p.errorf("unterminated bytes literal")
	}
	h := p.s[start:p.pos]
	p.pos++
	if len(h)%2 != 0 {
		return nil, p.errorf("odd number of hex digits")
	}
	out := make([]byte, len(h)/2)
	for i := range out {
		hi, lo := hexVal(h[2*i], false), hexVal(h[2*i+1], false)
		if hi < 0 || lo < 0 {
			return nil, p.errorf("invalid hex digit")
		}
		out[i] = byte(hi<<4 | lo)
	}
	return out, nil
}

func (p *textParser) parseString() ([]byte, error) {
	if !p.accept('"') {
		return nil, p.errorf("expected string literal")
	}
	out := []byte{}
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		p.pos++
		switch {
		case c == '"':
			return out, nil
		case c < 0x20:
			p.pos--
			return nil, p.errorf("control character in string literal")
		case c != '\\':
			out = append(out, c)
			continue
		}
		if p.pos >= len(p.s) {
			break
		}
		e := p.s[p.pos]
		p.pos++
		switch e {
		case '"', '\\':
			out = append(out, e)
		case 'n':
			out = append(out, '\n')
		case 'r':
			out = append(out, '\r')
		case 't':
			out = append(out, '\t')
		case 'x':
			if p.pos+2 > len(p.s) {
				return nil, p.errorf("truncated \\x escape")
			}
			hi, lo := hexVal(p.s[p.pos], true), hexVal(p.s[p.pos+1], true)
			if hi < 0 || lo < 0 {
				return nil, p.errorf("invalid \\x escape")
			}
			p.pos += 2
			out = append(out, byte(hi<<4|lo))
		default:
			p.pos--
			return nil, p.errorf("invalid escape")
		}
	}
	return nil, p.errorf("unterminated string literal")
}
