package codec

import "protowire/schema"

// node is one message instance in a value tree. slots has one entry per
// schema field, indexed by the field's position in number order.
type node struct {
	slots []slot
	seen  uint64 // encode: bit i set once field i has been given (≤ 64 fields)
	size  int    // encode: cached encoded size of the message body
}

// slot holds the value of one field:
//
//   - numeric scalar: n is the value in canonical form (signed kinds are
//     sign-extended to 64 bits, sint values are un-zigzagged, bool is 0/1);
//   - string/bytes: n is a view, see makeView;
//   - message: child is the sub-message (nil when absent);
//   - repeated: list holds the elements (nil until the first one); for
//     encode, n caches the packed payload size of a numeric list.
type slot struct {
	n     uint64
	child *node
	list  *list
}

// list stores repeated elements: nums holds numbers or views, nodes holds
// sub-messages.
type list struct {
	nums  []uint64
	nodes []*node
}

func newNode(m *schema.MessageType) *node {
	return &node{slots: make([]slot, len(m.Fields))}
}

// makeView packs an (offset, length) pair into a slot value.
func makeView(off, n int) uint64 { return uint64(off)<<32 | uint64(n) }

func viewParts(v uint64) (off, n int) { return int(v >> 32), int(uint32(v)) }

func viewLen(v uint64) int { return int(uint32(v)) }

func (l *list) count(k schema.Kind) int {
	if l == nil {
		return 0
	}
	if k == schema.Message {
		return len(l.nodes)
	}
	return len(l.nums)
}

// varintValue returns the value whose varint encoding represents the
// canonical value n of a varint-wire-type kind.
func varintValue(k schema.Kind, n uint64) uint64 {
	switch k {
	case schema.Sint32:
		return uint64(zigzag32(int32(n)))
	case schema.Sint64:
		return zigzag64(int64(n))
	}
	return n // int32/int64 are already sign-extended; uint and bool as is
}
