package codec

import (
	"protowire/schema"
	"protowire/wire"
)

// AppendEncode parses text as a message of type m and appends its canonical
// wire encoding to dst. On error dst is returned unchanged.
func (c *Codec) AppendEncode(dst []byte, m *schema.MessageType, text []byte) ([]byte, error) {
	if len(text) > maxBuffer {
		return dst, ErrTooLarge
	}
	p := textParser{c: c, s: c.schema, text: text, arena: c.arena[:0]}
	root, err := p.message(m, 0)
	if err == nil {
		p.skipSpaces()
		if p.pos != len(p.text) {
			err = ErrSyntax // trailing text
		}
	}
	c.arena = p.arena // keep the (possibly grown) scratch buffer
	if err != nil {
		return dst, err
	}
	e := encoder{buf: p.arena, schema: c.schema}
	total := e.size(m, root)
	if cap(dst)-len(dst) < total {
		grown := make([]byte, len(dst), len(dst)+total)
		copy(grown, dst)
		dst = grown
	}
	return e.write(dst, m, root), nil
}

type encoder struct {
	buf    []byte // arena holding string/bytes literals
	schema *schema.Schema
}

// elemSize is the size of one numeric value of kind k inside a packed list
// or as a singular field's payload.
func elemSize(k schema.Kind, n uint64) int {
	switch k.WireType() {
	case wire.Fixed32:
		return 4
	case wire.Fixed64:
		return 8
	}
	return wire.SizeVarint(varintValue(k, n))
}

func appendElem(dst []byte, k schema.Kind, n uint64) []byte {
	switch k.WireType() {
	case wire.Fixed32:
		return wire.AppendFixed32(dst, uint32(n))
	case wire.Fixed64:
		return wire.AppendFixed64(dst, n)
	}
	return wire.AppendVarint(dst, varintValue(k, n))
}

// size computes the encoded size of n's body bottom-up, caching it on every
// node (and the packed payload size of numeric lists in their slot).
func (e *encoder) size(m *schema.MessageType, n *node) int {
	total := 0
	for i := range m.Fields {
		f := &m.Fields[i]
		s := &n.slots[i]
		tag := len(f.Tag)
		switch {
		case f.Repeated && f.Kind == schema.Message:
			sub := &e.schema.Messages[f.Message]
			if s.list != nil {
				for _, c := range s.list.nodes {
					cs := e.size(sub, c)
					total += tag + wire.SizeVarint(uint64(cs)) + cs
				}
			}
		case f.Repeated && f.Kind.IsBytesLike():
			if s.list != nil {
				for _, v := range s.list.nums {
					l := viewLen(v)
					total += tag + wire.SizeVarint(uint64(l)) + l
				}
			}
		case f.Repeated:
			if s.list != nil && len(s.list.nums) > 0 {
				payload := 0
				for _, v := range s.list.nums {
					payload += elemSize(f.Kind, v)
				}
				s.n = uint64(payload)
				total += tag + wire.SizeVarint(uint64(payload)) + payload
			}
		case f.Kind == schema.Message:
			if s.child != nil {
				cs := e.size(&e.schema.Messages[f.Message], s.child)
				total += tag + wire.SizeVarint(uint64(cs)) + cs
			}
		case f.Kind.IsBytesLike():
			if l := viewLen(s.n); l > 0 {
				total += tag + wire.SizeVarint(uint64(l)) + l
			}
		default:
			if s.n != 0 {
				total += tag + elemSize(f.Kind, s.n)
			}
		}
	}
	n.size = total
	return total
}

// write appends n's body to dst, using the sizes cached by size.
func (e *encoder) write(dst []byte, m *schema.MessageType, n *node) []byte {
	for i := range m.Fields {
		f := &m.Fields[i]
		s := &n.slots[i]
		switch {
		case f.Repeated && f.Kind == schema.Message:
			if s.list != nil {
				sub := &e.schema.Messages[f.Message]
				for _, c := range s.list.nodes {
					dst = append(dst, f.Tag...)
					dst = wire.AppendVarint(dst, uint64(c.size))
					dst = e.write(dst, sub, c)
				}
			}
		case f.Repeated && f.Kind.IsBytesLike():
			if s.list != nil {
				for _, v := range s.list.nums {
					dst = e.appendBytes(dst, f.Tag, v)
				}
			}
		case f.Repeated:
			if s.list != nil && len(s.list.nums) > 0 {
				dst = append(dst, f.Tag...)
				dst = wire.AppendVarint(dst, s.n)
				for _, v := range s.list.nums {
					dst = appendElem(dst, f.Kind, v)
				}
			}
		case f.Kind == schema.Message:
			if s.child != nil {
				dst = append(dst, f.Tag...)
				dst = wire.AppendVarint(dst, uint64(s.child.size))
				dst = e.write(dst, &e.schema.Messages[f.Message], s.child)
			}
		case f.Kind.IsBytesLike():
			if viewLen(s.n) > 0 {
				dst = e.appendBytes(dst, f.Tag, s.n)
			}
		default:
			if s.n != 0 {
				dst = append(dst, f.Tag...)
				dst = appendElem(dst, f.Kind, s.n)
			}
		}
	}
	return dst
}

func (e *encoder) appendBytes(dst, tag []byte, view uint64) []byte {
	off, n := viewParts(view)
	dst = append(dst, tag...)
	dst = wire.AppendVarint(dst, uint64(n))
	return append(dst, e.buf[off:off+n]...)
}
