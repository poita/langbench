package protowire

// Message is a decoded (or parsed) message instance: a tree with one node per
// message. A Message is immutable once returned by this package.
type Message struct {
	desc  *MessageDesc
	slots []slot // indexed by Field.index
	size  int    // encoded size, filled in by Marshal
}

// scalar holds one element. Integers and bools are stored as 64-bit values:
// signed kinds sign-extended, unsigned kinds zero-extended.
type value struct {
	num uint64
	b   []byte   // string / bytes payload
	msg *Message // message value
}

type slot struct {
	set  bool
	v    value   // singular value
	list []value // repeated values
	plen int     // packed payload length (encode only)
}

func newMessage(d *MessageDesc) *Message {
	return &Message{desc: d, slots: make([]slot, len(d.Fields))}
}

// Desc returns the message's type.
func (m *Message) Desc() *MessageDesc { return m.desc }

// Get returns the value of the named field as a Go value, and whether the
// field is present (for repeated fields: has at least one element).
//
// Signed integer kinds yield int64, unsigned and fixed unsigned kinds uint64,
// bool yields bool, string yields string, bytes yields []byte, message yields
// *Message, and a repeated field yields a []any of those. Absent singular
// fields yield their zero value; absent repeated fields yield a nil []any.
// Get returns (nil, false) for a name the message does not have.
func (m *Message) Get(name string) (any, bool) {
	f := m.desc.byName[name]
	if f == nil {
		return nil, false
	}
	s := &m.slots[f.index]
	if f.Repeated {
		var out []any
		for _, v := range s.list {
			out = append(out, v.export(f))
		}
		return out, len(s.list) > 0
	}
	return s.v.export(f), s.set
}

func (v value) export(f *Field) any {
	switch {
	case f.Kind == KindBool:
		return v.num != 0
	case f.Kind == KindString:
		return string(v.b)
	case f.Kind == KindBytes:
		return append([]byte(nil), v.b...)
	case f.Kind == KindMessage:
		return v.msg
	case f.Kind.isSigned():
		return int64(v.num)
	}
	return v.num
}
