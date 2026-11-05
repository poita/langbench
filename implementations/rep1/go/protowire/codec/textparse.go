package codec

import (
	"unicode/utf8"

	"protowire/schema"
	"protowire/wire"
)

// textParser is a single-pass recursive-descent parser for the text form,
// building a value tree. String and bytes literals are unescaped straight
// into the Codec's arena; slots refer to them by (offset, length).
type textParser struct {
	c     *Codec
	s     *schema.Schema
	text  []byte
	pos   int
	arena []byte
}

func (p *textParser) skipSpaces() {
	for p.pos < len(p.text) && p.text[p.pos] == ' ' {
		p.pos++
	}
}

// accept skips spaces and consumes ch if it is next.
func (p *textParser) accept(ch byte) bool {
	p.skipSpaces()
	if p.pos < len(p.text) && p.text[p.pos] == ch {
		p.pos++
		return true
	}
	return false
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

func (p *textParser) word() []byte {
	start := p.pos
	for p.pos < len(p.text) && isWordByte(p.text[p.pos]) {
		p.pos++
	}
	return p.text[start:p.pos]
}

// message parses "{" [field ("," field)*] "}" into a new node.
func (p *textParser) message(m *schema.MessageType, depth int) (*node, error) {
	if depth > MaxDepth {
		return nil, ErrDepth
	}
	if !p.accept('{') {
		return nil, ErrSyntax
	}
	n := newNode(m)
	if p.accept('}') {
		return n, nil
	}
	for {
		p.skipSpaces()
		name := p.word()
		if len(name) == 0 {
			return nil, ErrSyntax
		}
		fi := m.FieldByName(name)
		if fi < 0 {
			return nil, ErrUnknownField
		}
		if n.seen&(1<<uint(fi)) != 0 {
			return nil, ErrDuplicate
		}
		n.seen |= 1 << uint(fi)
		if !p.accept(':') {
			return nil, ErrSyntax
		}
		p.skipSpaces()
		if err := p.field(m, &m.Fields[fi], &n.slots[fi], depth); err != nil {
			return nil, err
		}
		if p.accept(',') {
			continue
		}
		if p.accept('}') {
			return n, nil
		}
		return nil, ErrSyntax
	}
}

// field parses the value of field f into s.
func (p *textParser) field(m *schema.MessageType, f *schema.Field, s *slot, depth int) error {
	if !f.Repeated {
		if f.Kind == schema.Message {
			child, err := p.message(&p.s.Messages[f.Message], depth+1)
			s.child = child
			return err
		}
		v, err := p.scalar(f.Kind)
		s.n = v
		return err
	}
	if p.pos >= len(p.text) || p.text[p.pos] != '[' {
		return ErrBadValue
	}
	p.pos++
	if p.accept(']') {
		return nil
	}
	l := &list{}
	s.list = l
	for {
		p.skipSpaces()
		if f.Kind == schema.Message {
			child, err := p.message(&p.s.Messages[f.Message], depth+1)
			if err != nil {
				return err
			}
			l.nodes = append(l.nodes, child)
		} else {
			v, err := p.scalar(f.Kind)
			if err != nil {
				return err
			}
			l.nums = append(l.nums, v)
		}
		if p.accept(',') {
			continue
		}
		if p.accept(']') {
			return nil
		}
		return ErrSyntax
	}
}

// scalar parses one non-message value of kind k, returning its canonical
// slot value.
func (p *textParser) scalar(k schema.Kind) (uint64, error) {
	switch k {
	case schema.Bool:
		switch string(p.word()) {
		case "true":
			return 1, nil
		case "false":
			return 0, nil
		}
		return 0, ErrBadValue
	case schema.String:
		return p.stringLit()
	case schema.BytesKind:
		return p.bytesLit()
	}
	return p.integer(k)
}

// integer parses a decimal integer and range-checks it for kind k.
func (p *textParser) integer(k schema.Kind) (uint64, error) {
	neg := false
	if p.pos < len(p.text) && p.text[p.pos] == '-' {
		neg = true
		p.pos++
	}
	start := p.pos
	var v uint64
	for p.pos < len(p.text) {
		d := p.text[p.pos] - '0'
		if d > 9 {
			break
		}
		if v > (1<<64-1-uint64(d))/10 {
			return 0, ErrBadValue
		}
		v = v*10 + uint64(d)
		p.pos++
	}
	digits := p.pos - start
	if digits == 0 || digits > 1 && p.text[start] == '0' || neg && v == 0 {
		return 0, ErrBadValue
	}
	var bitsize uint
	switch k {
	case schema.Int32, schema.Sint32, schema.Sfixed32, schema.Uint32, schema.Fixed32:
		bitsize = 32
	default:
		bitsize = 64
	}
	if k.Signed() {
		limit := uint64(1) << (bitsize - 1)
		if neg {
			if v > limit {
				return 0, ErrBadValue
			}
			return -v, nil
		}
		if v >= limit {
			return 0, ErrBadValue
		}
		return v, nil
	}
	if neg || bitsize == 32 && v > 1<<32-1 {
		return 0, ErrBadValue
	}
	return v, nil
}

// stringLit parses a double-quoted string literal with escapes into the
// arena and returns a view of its unescaped bytes.
func (p *textParser) stringLit() (uint64, error) {
	if p.pos >= len(p.text) || p.text[p.pos] != '"' {
		return 0, ErrBadValue
	}
	p.pos++
	start := len(p.arena)
	for {
		// Copy the run of ordinary bytes in bulk.
		runStart := p.pos
		for p.pos < len(p.text) {
			c := p.text[p.pos]
			if c == '"' || c == '\\' || c < 0x20 {
				break
			}
			p.pos++
		}
		p.arena = append(p.arena, p.text[runStart:p.pos]...)
		if p.pos >= len(p.text) {
			return 0, ErrSyntax // unterminated
		}
		c := p.text[p.pos]
		p.pos++
		switch {
		case c == '"':
			lit := p.arena[start:]
			if !utf8.Valid(lit) {
				return 0, ErrBadUTF8
			}
			return makeView(start, len(lit)), nil
		case c < 0x20:
			return 0, ErrSyntax
		}
		// backslash escape
		if p.pos >= len(p.text) {
			return 0, ErrSyntax
		}
		e := p.text[p.pos]
		p.pos++
		switch e {
		case '"', '\\':
			p.arena = append(p.arena, e)
		case 'n':
			p.arena = append(p.arena, '\n')
		case 'r':
			p.arena = append(p.arena, '\r')
		case 't':
			p.arena = append(p.arena, '\t')
		case 'x':
			if p.pos+2 > len(p.text) {
				return 0, ErrSyntax
			}
			hi, ok1 := hexDigit(p.text[p.pos])
			lo, ok2 := hexDigit(p.text[p.pos+1])
			if !ok1 || !ok2 {
				return 0, ErrSyntax
			}
			p.pos += 2
			p.arena = append(p.arena, hi<<4|lo)
		default:
			return 0, ErrSyntax
		}
	}
}

// hexDigit accepts hex digits of either case (used inside \xHH escapes).
func hexDigit(c byte) (byte, bool) {
	if c >= 'A' && c <= 'F' {
		c += 'a' - 'A'
	}
	return wire.HexValue(c)
}

// bytesLit parses x"<lowercase hex>" into the arena.
func (p *textParser) bytesLit() (uint64, error) {
	if p.pos+1 >= len(p.text) || p.text[p.pos] != 'x' || p.text[p.pos+1] != '"' {
		return 0, ErrBadValue
	}
	p.pos += 2
	end := p.pos
	for end < len(p.text) && p.text[end] != '"' {
		end++
	}
	if end >= len(p.text) {
		return 0, ErrSyntax
	}
	start := len(p.arena)
	arena, ok := wire.AppendUnhex(p.arena, p.text[p.pos:end])
	if !ok {
		return 0, ErrBadValue
	}
	p.arena = arena
	p.pos = end + 1
	return makeView(start, len(arena)-start), nil
}
