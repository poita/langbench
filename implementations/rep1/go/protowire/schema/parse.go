package schema

import (
	"fmt"
	"sort"
	"strconv"

	"protowire/wire"
)

// MaxFields is the largest number of fields a message may declare.
const MaxFields = 64

// MaxFieldNumber is the largest legal field number.
const MaxFieldNumber = 1<<29 - 1

var scalarKinds = map[string]Kind{
	"int32": Int32, "int64": Int64, "uint32": Uint32, "uint64": Uint64,
	"sint32": Sint32, "sint64": Sint64, "bool": Bool,
	"fixed32": Fixed32, "fixed64": Fixed64, "sfixed32": Sfixed32, "sfixed64": Sfixed64,
	"string": String, "bytes": BytesKind,
}

type token struct {
	text string
	pos  int // byte offset in the source, for error messages
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

func tokenize(src []byte) ([]token, error) {
	var toks []token
	for i := 0; i < len(src); {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case c == '{' || c == '}' || c == ';' || c == '=':
			toks = append(toks, token{string(c), i})
			i++
		case isWordByte(c):
			j := i
			for j < len(src) && isWordByte(src[j]) {
				j++
			}
			toks = append(toks, token{string(src[i:j]), i})
			i = j
		default:
			return nil, fmt.Errorf("schema: unexpected character %q at offset %d", c, i)
		}
	}
	return toks, nil
}

type rawField struct {
	name     string
	typeName string
	number   uint32
	repeated bool
}

type rawMessage struct {
	name   string
	fields []rawField
}

// Parse compiles schema source text into a Schema. Types may refer to
// messages defined later in the source, or to the message being defined.
func Parse(src []byte) (*Schema, error) {
	toks, err := tokenize(src)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	var raws []rawMessage
	for !p.done() {
		m, err := p.message()
		if err != nil {
			return nil, err
		}
		raws = append(raws, m)
	}
	return compile(raws)
}

type parser struct {
	toks []token
	i    int
}

func (p *parser) done() bool { return p.i >= len(p.toks) }

func (p *parser) next(what string) (token, error) {
	if p.done() {
		return token{}, fmt.Errorf("schema: unexpected end of input, expected %s", what)
	}
	t := p.toks[p.i]
	p.i++
	return t, nil
}

func (p *parser) expect(text string) error {
	t, err := p.next(strconv.Quote(text))
	if err != nil {
		return err
	}
	if t.text != text {
		return fmt.Errorf("schema: expected %q, found %q at offset %d", text, t.text, t.pos)
	}
	return nil
}

func isIdent(s string) bool {
	if s == "" || s[0] >= '0' && s[0] <= '9' {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isWordByte(s[i]) {
			return false
		}
	}
	return true
}

func (p *parser) ident(what string) (string, error) {
	t, err := p.next(what)
	if err != nil {
		return "", err
	}
	if !isIdent(t.text) {
		return "", fmt.Errorf("schema: expected %s, found %q at offset %d", what, t.text, t.pos)
	}
	return t.text, nil
}

func (p *parser) message() (rawMessage, error) {
	var m rawMessage
	if err := p.expect("message"); err != nil {
		return m, err
	}
	name, err := p.ident("message name")
	if err != nil {
		return m, err
	}
	if _, reserved := scalarKinds[name]; reserved || name == "message" || name == "repeated" {
		return m, fmt.Errorf("schema: %q is reserved and cannot name a message", name)
	}
	m.name = name
	if err := p.expect("{"); err != nil {
		return m, err
	}
	for {
		t, err := p.next("field or }")
		if err != nil {
			return m, err
		}
		if t.text == "}" {
			return m, nil
		}
		var f rawField
		if t.text == "repeated" {
			f.repeated = true
			if t, err = p.next("field type"); err != nil {
				return m, err
			}
		}
		if !isIdent(t.text) || t.text == "message" || t.text == "repeated" {
			return m, fmt.Errorf("schema: invalid field type %q at offset %d", t.text, t.pos)
		}
		f.typeName = t.text
		if f.name, err = p.ident("field name"); err != nil {
			return m, err
		}
		if _, reserved := scalarKinds[f.name]; reserved || f.name == "message" || f.name == "repeated" {
			return m, fmt.Errorf("schema: %q is reserved and cannot name a field", f.name)
		}
		if err := p.expect("="); err != nil {
			return m, err
		}
		nt, err := p.next("field number")
		if err != nil {
			return m, err
		}
		n, err := strconv.ParseUint(nt.text, 10, 32)
		if err != nil || n < 1 || n > MaxFieldNumber {
			return m, fmt.Errorf("schema: invalid field number %q at offset %d", nt.text, nt.pos)
		}
		f.number = uint32(n)
		if err := p.expect(";"); err != nil {
			return m, err
		}
		m.fields = append(m.fields, f)
	}
}

func compile(raws []rawMessage) (*Schema, error) {
	s := &Schema{
		Messages: make([]MessageType, len(raws)),
		byName:   make(map[string]int, len(raws)),
	}
	for i, r := range raws {
		if _, dup := s.byName[r.name]; dup {
			return nil, fmt.Errorf("schema: message %q defined twice", r.name)
		}
		s.byName[r.name] = i
	}
	for i, r := range raws {
		if len(r.fields) > MaxFields {
			return nil, fmt.Errorf("schema: message %q has more than %d fields", r.name, MaxFields)
		}
		fields := make([]Field, len(r.fields))
		for j, rf := range r.fields {
			f := Field{Name: rf.name, Number: rf.number, Repeated: rf.repeated}
			if k, ok := scalarKinds[rf.typeName]; ok {
				f.Kind = k
			} else if idx, ok := s.byName[rf.typeName]; ok {
				f.Kind, f.Message = Message, idx
			} else {
				return nil, fmt.Errorf("schema: message %q field %q: unknown type %q", r.name, rf.name, rf.typeName)
			}
			f.WireType = f.Kind.WireType()
			tagType := f.WireType
			if f.Repeated && f.Kind.IsNumeric() {
				tagType = wire.Bytes
			}
			f.Tag = wire.AppendTag(nil, f.Number, tagType)
			fields[j] = f
		}
		sort.Slice(fields, func(a, b int) bool { return fields[a].Number < fields[b].Number })
		m := &s.Messages[i]
		m.Name = r.name
		m.Fields = fields
		m.numbers = make([]uint32, len(fields))
		m.byName = make(map[string]int, len(fields))
		for j, f := range fields {
			if j > 0 && fields[j-1].Number == f.Number {
				return nil, fmt.Errorf("schema: message %q: duplicate field number %d", r.name, f.Number)
			}
			if _, dup := m.byName[f.Name]; dup {
				return nil, fmt.Errorf("schema: message %q: duplicate field name %q", r.name, f.Name)
			}
			m.numbers[j] = f.Number
			m.byName[f.Name] = j
		}
	}
	return s, nil
}
