package protowire

import "unicode/utf8"

// Unmarshal decodes wire-format data as a message of type d, following proto3
// semantics: unknown fields and fields with the wrong wire type are skipped,
// later scalars replace earlier ones, repeated fields append (packed or not),
// and repeated occurrences of a singular message field are merged.
//
// Unmarshal never panics on malformed input; it returns an error wrapping
// [ErrDecode]. It reads each input byte a constant number of times, and
// string and bytes values in the result alias data.
func (d *MessageDesc) Unmarshal(data []byte) (*Message, error) {
	m := newMessage(d)
	if err := m.decode(data, 0); err != nil {
		return nil, err
	}
	return m, nil
}

func (m *Message) decode(b []byte, depth int) error {
	if depth > MaxDepth {
		return errTooDeep
	}
	pos := 0
	for pos < len(b) {
		num, wt, p, err := readTag(b, pos)
		if err != nil {
			return err
		}
		pos = p
		f := m.desc.byNumber[num]
		if f == nil {
			if pos, err = skipField(b, pos, num, wt); err != nil {
				return err
			}
			continue
		}
		s := &m.slots[f.index]
		switch {
		case f.Kind == KindMessage || f.Kind == KindString || f.Kind == KindBytes:
			if wt != wireBytes {
				if pos, err = skipField(b, pos, num, wt); err != nil {
					return err
				}
				continue
			}
			n, p, err := readLen(b, pos)
			if err != nil {
				return err
			}
			payload := b[p : p+n : p+n]
			pos = p + n
			switch f.Kind {
			case KindString:
				if !utf8.Valid(payload) {
					return errBadUTF8
				}
				s.store(f, value{b: payload})
			case KindBytes:
				s.store(f, value{b: payload})
			default:
				var sub *Message
				if !f.Repeated && s.set {
					sub = s.v.msg
				} else {
					sub = newMessage(f.Message)
					s.store(f, value{msg: sub})
				}
				if err := sub.decode(payload, depth+1); err != nil {
					return err
				}
			}
		case wt == f.Kind.wireType():
			var v value
			if v.num, pos, err = readScalar(b, pos, f.Kind); err != nil {
				return err
			}
			s.store(f, v)
		case wt == wireBytes && f.Repeated:
			n, p, err := readLen(b, pos)
			if err != nil {
				return err
			}
			if err := s.decodePacked(f, b[p:p+n]); err != nil {
				return err
			}
			pos = p + n
		default:
			if pos, err = skipField(b, pos, num, wt); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *slot) store(f *Field, v value) {
	s.set = true
	if f.Repeated {
		s.list = append(s.list, v)
	} else {
		s.v = v
	}
}

func (s *slot) decodePacked(f *Field, payload []byte) error {
	s.set = true
	switch f.Kind.wireType() {
	case wireFixed32, wireFixed64:
		size := 4
		if f.Kind.wireType() == wireFixed64 {
			size = 8
		}
		if len(payload)%size != 0 {
			return errBadPacked
		}
		if s.list == nil {
			s.list = make([]value, 0, len(payload)/size)
		}
		for pos := 0; pos < len(payload); {
			num, p, err := readScalar(payload, pos, f.Kind)
			if err != nil {
				return err
			}
			s.list = append(s.list, value{num: num})
			pos = p
		}
	default:
		for pos := 0; pos < len(payload); {
			num, p, err := readScalar(payload, pos, f.Kind)
			if err != nil {
				return errBadPacked
			}
			s.list = append(s.list, value{num: num})
			pos = p
		}
	}
	return nil
}

// readScalar reads one value of numeric kind k (in its own wire type) and
// converts it to the 64-bit stored form.
func readScalar(b []byte, pos int, k Kind) (uint64, int, error) {
	switch k {
	case KindFixed32, KindSfixed32:
		if len(b)-pos < 4 {
			return 0, 0, errTruncated
		}
		u := uint32(b[pos]) | uint32(b[pos+1])<<8 | uint32(b[pos+2])<<16 | uint32(b[pos+3])<<24
		if k == KindSfixed32 {
			return uint64(int64(int32(u))), pos + 4, nil
		}
		return uint64(u), pos + 4, nil
	case KindFixed64, KindSfixed64:
		if len(b)-pos < 8 {
			return 0, 0, errTruncated
		}
		var u uint64
		for i := 7; i >= 0; i-- {
			u = u<<8 | uint64(b[pos+i])
		}
		return u, pos + 8, nil
	}
	v, p, err := readVarint(b, pos, maxVarintLen)
	if err != nil {
		return 0, 0, err
	}
	switch k {
	case KindInt32:
		v = uint64(int64(int32(uint32(v))))
	case KindUint32:
		v = uint64(uint32(v))
	case KindSint32:
		v = uint64(int64(unzigzag32(uint32(v))))
	case KindSint64:
		v = uint64(unzigzag64(v))
	case KindBool:
		if v != 0 {
			v = 1
		}
	}
	return v, p, nil
}
