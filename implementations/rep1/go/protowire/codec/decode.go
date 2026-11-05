package codec

import (
	"slices"
	"unicode/utf8"

	"protowire/schema"
	"protowire/wire"
)

var (
	zigzag32 = wire.ZigZag32
	zigzag64 = wire.ZigZag64
)

// AppendDecode decodes data as message type m and appends its canonical text
// form to dst. On error dst is returned unchanged.
func (c *Codec) AppendDecode(dst []byte, m *schema.MessageType, data []byte) ([]byte, error) {
	if len(data) > maxBuffer {
		return dst, ErrTooLarge
	}
	d := decoder{c: c, buf: data}
	root := newNode(m)
	if err := d.message(m, root, 0, len(data), 0); err != nil {
		return dst, err
	}
	r := renderer{buf: data, schema: c.schema}
	return r.message(dst, m, root), nil
}

type decoder struct {
	c   *Codec
	buf []byte
}

// readTag reads a tag at pos, enforcing the 5-byte and 2^32 limits.
func (d *decoder) readTag(pos, end int) (number uint32, wt int, next int, err error) {
	tag, n, err := wire.ConsumeVarint(d.buf[pos:end], wire.MaxTagLen)
	if err != nil || tag>>32 != 0 {
		return 0, 0, 0, ErrBadTag
	}
	number, wt = uint32(tag>>3), int(tag&7)
	if number == 0 || wt == 6 || wt == 7 {
		return 0, 0, 0, ErrBadTag
	}
	return number, wt, pos + n, nil
}

// readLen reads a length prefix at pos; the length must fit before end.
func (d *decoder) readLen(pos, end int) (length int, next int, err error) {
	v, n, err := wire.ConsumeVarint(d.buf[pos:end], wire.MaxLenPrefixLen)
	if err != nil || v > uint64(end-pos-n) {
		return 0, 0, ErrBadLength
	}
	return int(v), pos + n, nil
}

// message decodes the fields in buf[pos:end] into n.
func (d *decoder) message(m *schema.MessageType, n *node, pos, end, depth int) error {
	if depth > MaxDepth {
		return ErrDepth
	}
	for pos < end {
		number, wt, p, err := d.readTag(pos, end)
		if err != nil {
			return err
		}
		pos = p
		if wt == wire.EndGroup {
			return ErrBadGroup
		}
		fi := m.FieldByNumber(number)
		if fi < 0 {
			if pos, err = d.skip(pos, end, wt, number); err != nil {
				return err
			}
			continue
		}
		f := &m.Fields[fi]
		s := &n.slots[fi]
		switch {
		case wt == wire.Bytes && f.Kind.IsNumeric():
			if !f.Repeated {
				pos, err = d.skip(pos, end, wt, number)
				break
			}
			var length int
			if length, pos, err = d.readLen(pos, end); err != nil {
				return err
			}
			err = d.packed(f, s, pos, pos+length)
			pos += length
		case wt == wire.Bytes:
			var length int
			if length, pos, err = d.readLen(pos, end); err != nil {
				return err
			}
			err = d.bytesField(f, s, pos, pos+length, depth)
			pos += length
		case wt == f.WireType:
			var v uint64
			if v, pos, err = d.scalar(f.Kind, pos, end); err != nil {
				return err
			}
			if f.Repeated {
				s.appendNum(v)
			} else {
				s.n = v
			}
		default: // known field, wrong wire type: treat as unknown
			pos, err = d.skip(pos, end, wt, number)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *slot) appendNum(v uint64) {
	if s.list == nil {
		s.list = &list{}
	}
	s.list.nums = append(s.list.nums, v)
}

// scalar reads one value of numeric kind k whose wire type matches the
// kind's own, returning it in canonical form.
func (d *decoder) scalar(k schema.Kind, pos, end int) (uint64, int, error) {
	switch k.WireType() {
	case wire.Varint:
		v, n, err := wire.ConsumeVarint(d.buf[pos:end], wire.MaxVarintLen)
		if err != nil {
			return 0, 0, ErrTruncated
		}
		return fromVarint(k, v), pos + n, nil
	case wire.Fixed32:
		if end-pos < 4 {
			return 0, 0, ErrTruncated
		}
		v := wire.ReadFixed32(d.buf[pos:])
		if k == schema.Sfixed32 {
			return uint64(int64(int32(v))), pos + 4, nil
		}
		return uint64(v), pos + 4, nil
	default: // Fixed64
		if end-pos < 8 {
			return 0, 0, ErrTruncated
		}
		return wire.ReadFixed64(d.buf[pos:]), pos + 8, nil
	}
}

// fromVarint converts a raw varint to the canonical value of kind k.
func fromVarint(k schema.Kind, v uint64) uint64 {
	switch k {
	case schema.Int32:
		return uint64(int64(int32(v)))
	case schema.Uint32:
		return uint64(uint32(v))
	case schema.Sint32:
		return uint64(int64(wire.UnZigZag32(uint32(v))))
	case schema.Sint64:
		return uint64(wire.UnZigZag64(v))
	case schema.Bool:
		if v != 0 {
			return 1
		}
		return 0
	}
	return v // int64, uint64
}

// packed decodes the elements of a packed repeated numeric field.
func (d *decoder) packed(f *schema.Field, s *slot, pos, end int) error {
	if s.list == nil {
		s.list = &list{}
	}
	l := s.list
	switch f.WireType {
	case wire.Fixed32, wire.Fixed64:
		size := 4
		if f.WireType == wire.Fixed64 {
			size = 8
		}
		if (end-pos)%size != 0 {
			return ErrBadPacked
		}
		l.nums = slices.Grow(l.nums, (end-pos)/size)
	}
	for pos < end {
		v, p, err := d.scalar(f.Kind, pos, end)
		if err != nil {
			return ErrBadPacked
		}
		l.nums = append(l.nums, v)
		pos = p
	}
	return nil
}

// bytesField handles a length-delimited occurrence of a string, bytes or
// message field whose payload is buf[pos:end].
func (d *decoder) bytesField(f *schema.Field, s *slot, pos, end, depth int) error {
	switch f.Kind {
	case schema.String, schema.BytesKind:
		if f.Kind == schema.String && !utf8.Valid(d.buf[pos:end]) {
			return ErrBadUTF8
		}
		v := makeView(pos, end-pos)
		if f.Repeated {
			s.appendNum(v)
		} else {
			s.n = v
		}
		return nil
	}
	sub := &d.c.schema.Messages[f.Message]
	var child *node
	if f.Repeated {
		child = newNode(sub)
		if s.list == nil {
			s.list = &list{}
		}
		s.list.nodes = append(s.list.nodes, child)
	} else {
		if s.child == nil {
			s.child = newNode(sub)
		}
		child = s.child
	}
	return d.message(sub, child, pos, end, depth+1)
}

// skip advances over the payload of a field whose tag (number, wt) has just
// been read, validating only what skipping requires. Groups are skipped
// iteratively with an explicit stack of open field numbers.
func (d *decoder) skip(pos, end, wt int, number uint32) (int, error) {
	stack := d.c.groups[:0]
	defer func() { d.c.groups = stack[:0] }()
	for {
		switch wt {
		case wire.Varint:
			_, n, err := wire.ConsumeVarint(d.buf[pos:end], wire.MaxVarintLen)
			if err != nil {
				return 0, ErrTruncated
			}
			pos += n
		case wire.Fixed64:
			if end-pos < 8 {
				return 0, ErrTruncated
			}
			pos += 8
		case wire.Fixed32:
			if end-pos < 4 {
				return 0, ErrTruncated
			}
			pos += 4
		case wire.Bytes:
			length, p, err := d.readLen(pos, end)
			if err != nil {
				return 0, err
			}
			pos = p + length
		case wire.StartGroup:
			if len(stack) >= MaxDepth {
				return 0, ErrDepth
			}
			stack = append(stack, number)
		case wire.EndGroup:
			if len(stack) == 0 || stack[len(stack)-1] != number {
				return 0, ErrBadGroup
			}
			stack = stack[:len(stack)-1]
		}
		if len(stack) == 0 {
			return pos, nil
		}
		if pos >= end {
			return 0, ErrBadGroup // data ended before the group closed
		}
		var err error
		if number, wt, pos, err = d.readTag(pos, end); err != nil {
			return 0, err
		}
	}
}
