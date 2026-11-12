package protowire

// Marshal returns the canonical wire encoding of m: fields in increasing
// field-number order, default singular scalars omitted, present singular
// messages always emitted, repeated numeric fields packed, and all varints
// minimal.
//
// Marshal runs in time linear in the size of the message tree plus the size
// of the output: every node's encoded size is computed once, bottom-up, and
// the output buffer is then allocated at its exact size and filled in a
// single pass.
func (m *Message) Marshal() []byte {
	n := m.computeSize()
	return m.appendTo(make([]byte, 0, n))
}

func tagLen(f *Field) int { return varintLen(uint64(f.Number) << 3) }

// scalarLen is the encoded size of one numeric element of kind k.
func scalarLen(k Kind, num uint64) int {
	switch k.wireType() {
	case wireFixed32:
		return 4
	case wireFixed64:
		return 8
	}
	return varintLen(wireVarintValue(k, num))
}

// wireVarintValue maps the stored form of a varint-encoded value to the
// integer that is written on the wire.
func wireVarintValue(k Kind, num uint64) uint64 {
	switch k {
	case KindSint32:
		return zigzag32(int32(num))
	case KindSint64:
		return zigzag64(int64(num))
	}
	return num // int32/int64 are stored sign-extended; bool is 0 or 1
}

// computeSize fills in size and slot.plen throughout the subtree.
func (m *Message) computeSize() int {
	total := 0
	for i, f := range m.desc.Fields {
		s := &m.slots[i]
		tl := tagLen(f)
		switch {
		case f.Repeated && f.Kind.isNumeric():
			if len(s.list) == 0 {
				continue
			}
			plen := 0
			switch f.Kind.wireType() {
			case wireFixed32:
				plen = 4 * len(s.list)
			case wireFixed64:
				plen = 8 * len(s.list)
			default:
				for _, v := range s.list {
					plen += varintLen(wireVarintValue(f.Kind, v.num))
				}
			}
			s.plen = plen
			total += tl + varintLen(uint64(plen)) + plen
		case f.Repeated:
			for _, v := range s.list {
				total += tl + elemSize(f, v)
			}
		case f.Kind == KindMessage:
			if s.set {
				total += tl + elemSize(f, s.v)
			}
		case f.Kind == KindString || f.Kind == KindBytes:
			if s.set && len(s.v.b) > 0 {
				total += tl + elemSize(f, s.v)
			}
		default:
			if s.set && s.v.num != 0 {
				total += tl + scalarLen(f.Kind, s.v.num)
			}
		}
	}
	m.size = total
	return total
}

// elemSize is the size of a length-delimited element after its tag (message,
// string or bytes), computing the sub-message size if needed.
func elemSize(f *Field, v value) int {
	if f.Kind == KindMessage {
		n := v.msg.computeSize()
		return varintLen(uint64(n)) + n
	}
	return varintLen(uint64(len(v.b))) + len(v.b)
}

func (m *Message) appendTo(dst []byte) []byte {
	for i, f := range m.desc.Fields {
		s := &m.slots[i]
		tag := uint64(f.Number) << 3
		switch {
		case f.Repeated && f.Kind.isNumeric():
			if len(s.list) == 0 {
				continue
			}
			dst = appendVarint(dst, tag|wireBytes)
			dst = appendVarint(dst, uint64(s.plen))
			for _, v := range s.list {
				dst = appendScalar(dst, f.Kind, v.num)
			}
		case f.Repeated:
			for _, v := range s.list {
				dst = appendLenDelimited(dst, tag, f, v)
			}
		case f.Kind == KindMessage:
			if s.set {
				dst = appendLenDelimited(dst, tag, f, s.v)
			}
		case f.Kind == KindString || f.Kind == KindBytes:
			if s.set && len(s.v.b) > 0 {
				dst = appendLenDelimited(dst, tag, f, s.v)
			}
		default:
			if s.set && s.v.num != 0 {
				dst = appendVarint(dst, tag|f.Kind.wireType())
				dst = appendScalar(dst, f.Kind, s.v.num)
			}
		}
	}
	return dst
}

func appendLenDelimited(dst []byte, tag uint64, f *Field, v value) []byte {
	dst = appendVarint(dst, tag|wireBytes)
	if f.Kind == KindMessage {
		dst = appendVarint(dst, uint64(v.msg.size))
		return v.msg.appendTo(dst)
	}
	dst = appendVarint(dst, uint64(len(v.b)))
	return append(dst, v.b...)
}

func appendScalar(dst []byte, k Kind, num uint64) []byte {
	switch k.wireType() {
	case wireFixed32:
		return append(dst, byte(num), byte(num>>8), byte(num>>16), byte(num>>24))
	case wireFixed64:
		return append(dst, byte(num), byte(num>>8), byte(num>>16), byte(num>>24),
			byte(num>>32), byte(num>>40), byte(num>>48), byte(num>>56))
	}
	return appendVarint(dst, wireVarintValue(k, num))
}
