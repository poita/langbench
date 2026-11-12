package protowire

import (
	"errors"
	"fmt"
	"sort"
)

// ErrSchema is wrapped by every error returned from [ParseSchema].
var ErrSchema = errors.New("protowire: invalid schema")

// Kind is the type of a field: one of the scalar types or a message.
type Kind uint8

// The field kinds.
const (
	KindInt32 Kind = iota + 1
	KindInt64
	KindUint32
	KindUint64
	KindSint32
	KindSint64
	KindBool
	KindFixed32
	KindFixed64
	KindSfixed32
	KindSfixed64
	KindString
	KindBytes
	KindMessage
)

var kindNames = [...]string{
	KindInt32: "int32", KindInt64: "int64", KindUint32: "uint32",
	KindUint64: "uint64", KindSint32: "sint32", KindSint64: "sint64",
	KindBool: "bool", KindFixed32: "fixed32", KindFixed64: "fixed64",
	KindSfixed32: "sfixed32", KindSfixed64: "sfixed64",
	KindString: "string", KindBytes: "bytes", KindMessage: "message",
}

var scalarKinds = func() map[string]Kind {
	m := make(map[string]Kind)
	for k := KindInt32; k < KindMessage; k++ {
		m[kindNames[k]] = k
	}
	return m
}()

// String returns the schema keyword for the kind ("int32", "string", ...).
func (k Kind) String() string {
	if int(k) < len(kindNames) && kindNames[k] != "" {
		return kindNames[k]
	}
	return fmt.Sprintf("Kind(%d)", uint8(k))
}

// Wire types of the protobuf wire format.
const (
	wireVarint   = 0
	wireFixed64  = 1
	wireBytes    = 2
	wireStartGrp = 3
	wireEndGrp   = 4
	wireFixed32  = 5
)

// wireType returns the wire type a (non-packed) value of kind k uses.
func (k Kind) wireType() uint64 {
	switch k {
	case KindFixed32, KindSfixed32:
		return wireFixed32
	case KindFixed64, KindSfixed64:
		return wireFixed64
	case KindString, KindBytes, KindMessage:
		return wireBytes
	}
	return wireVarint
}

// isNumeric reports whether k is a packable (numeric or bool) kind.
func (k Kind) isNumeric() bool { return k < KindString }

// isSigned reports whether integer values of kind k print as signed.
func (k Kind) isSigned() bool {
	switch k {
	case KindInt32, KindInt64, KindSint32, KindSint64, KindSfixed32, KindSfixed64:
		return true
	}
	return false
}

// Field describes one field of a message.
type Field struct {
	Name     string
	Number   uint32
	Kind     Kind
	Repeated bool
	// Message is the field's message type when Kind is KindMessage.
	Message *MessageDesc

	index int // position within MessageDesc.Fields
}

// MessageDesc describes a message type.
type MessageDesc struct {
	Name string
	// Fields lists the fields sorted by increasing field number.
	Fields []*Field

	byNumber map[uint32]*Field
	byName   map[string]*Field
}

// FieldByNumber returns the field with the given number, or nil.
func (d *MessageDesc) FieldByNumber(n uint32) *Field { return d.byNumber[n] }

// FieldByName returns the field with the given name, or nil.
func (d *MessageDesc) FieldByName(name string) *Field { return d.byName[name] }

// Schema is a set of message descriptors.
type Schema struct {
	messages map[string]*MessageDesc
	order    []*MessageDesc
}

// Message returns the message type with the given name, or nil.
func (s *Schema) Message(name string) *MessageDesc { return s.messages[name] }

// Messages returns all message types in definition order.
func (s *Schema) Messages() []*MessageDesc { return s.order }

// rawField is a field before its type has been resolved.
type rawField struct {
	typ      string
	name     string
	number   uint32
	repeated bool
}

type rawMessage struct {
	name   string
	fields []rawField
}

// ParseSchema parses schema source text: a sequence of
//
//	message Name { [repeated] type name = number; ... }
//
// definitions. Message types may refer to each other freely, including
// recursively and before their definition.
func ParseSchema(src string) (*Schema, error) {
	toks := tokenize(src)
	var raws []rawMessage
	for i := 0; i < len(toks); {
		var m rawMessage
		var err error
		m, i, err = parseMessageDef(toks, i)
		if err != nil {
			return nil, err
		}
		raws = append(raws, m)
	}

	s := &Schema{messages: make(map[string]*MessageDesc, len(raws))}
	for _, r := range raws {
		if _, dup := s.messages[r.name]; dup {
			return nil, fmt.Errorf("%w: duplicate message %q", ErrSchema, r.name)
		}
		d := &MessageDesc{
			Name:     r.name,
			byNumber: make(map[uint32]*Field, len(r.fields)),
			byName:   make(map[string]*Field, len(r.fields)),
		}
		s.messages[r.name] = d
		s.order = append(s.order, d)
	}
	for i, r := range raws {
		d := s.order[i]
		for _, rf := range r.fields {
			f := &Field{Name: rf.name, Number: rf.number, Repeated: rf.repeated}
			if k, ok := scalarKinds[rf.typ]; ok {
				f.Kind = k
			} else if md := s.messages[rf.typ]; md != nil {
				f.Kind, f.Message = KindMessage, md
			} else {
				return nil, fmt.Errorf("%w: unknown type %q", ErrSchema, rf.typ)
			}
			if d.byName[f.Name] != nil || d.byNumber[f.Number] != nil {
				return nil, fmt.Errorf("%w: duplicate field %q = %d in %s", ErrSchema, f.Name, f.Number, d.Name)
			}
			d.byName[f.Name] = f
			d.byNumber[f.Number] = f
			d.Fields = append(d.Fields, f)
		}
		sort.Slice(d.Fields, func(a, b int) bool { return d.Fields[a].Number < d.Fields[b].Number })
		for j, f := range d.Fields {
			f.index = j
		}
	}
	return s, nil
}

func isTokenByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

// tokenize splits src into punctuation tokens ({ } ; =) and identifier/number
// runs. Any other byte is returned as a one-byte token and later rejected by
// the parser.
func tokenize(src string) []string {
	var toks []string
	for i := 0; i < len(src); {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case isTokenByte(c):
			j := i + 1
			for j < len(src) && isTokenByte(src[j]) {
				j++
			}
			toks = append(toks, src[i:j])
			i = j
		default:
			toks = append(toks, src[i:i+1])
			i++
		}
	}
	return toks
}

func parseMessageDef(toks []string, i int) (rawMessage, int, error) {
	var m rawMessage
	bad := func(want string) (rawMessage, int, error) {
		got := "end of input"
		if i < len(toks) {
			got = fmt.Sprintf("%q", toks[i])
		}
		return m, i, fmt.Errorf("%w: expected %s, found %s", ErrSchema, want, got)
	}
	at := func(s string) bool { return i < len(toks) && toks[i] == s }

	if !at("message") {
		return bad(`"message"`)
	}
	i++
	if i >= len(toks) || !isIdent(toks[i]) {
		return bad("message name")
	}
	m.name = toks[i]
	i++
	if !at("{") {
		return bad(`"{"`)
	}
	i++
	for !at("}") {
		var f rawField
		if at("repeated") {
			f.repeated = true
			i++
		}
		if i >= len(toks) || !isIdent(toks[i]) {
			return bad("field type")
		}
		f.typ = toks[i]
		i++
		if i >= len(toks) || !isIdent(toks[i]) {
			return bad("field name")
		}
		f.name = toks[i]
		i++
		if !at("=") {
			return bad(`"="`)
		}
		i++
		if i >= len(toks) {
			return bad("field number")
		}
		var n uint64
		for _, c := range []byte(toks[i]) {
			if c < '0' || c > '9' || n > 1<<29 {
				return bad("field number")
			}
			n = n*10 + uint64(c-'0')
		}
		if n < 1 || n > 536870911 || (n >= 19000 && n <= 19999) {
			return bad("field number in 1..536870911")
		}
		f.number = uint32(n)
		i++
		if !at(";") {
			return bad(`";"`)
		}
		i++
		m.fields = append(m.fields, f)
	}
	i++ // "}"
	return m, i, nil
}

func isIdent(t string) bool {
	if t == "" || t[0] >= '0' && t[0] <= '9' || !isTokenByte(t[0]) {
		return false
	}
	return t != "message" && t != "repeated"
}
