package jsonschema

// bitset is a growable set of small non-negative integers.
type bitset []uint64

func (b *bitset) set(i int) {
	w := i >> 6
	if w >= len(*b) {
		*b = append(*b, make([]uint64, w+1-len(*b))...)
	}
	(*b)[w] |= 1 << (uint(i) & 63)
}

func (b bitset) has(i int) bool {
	w := i >> 6
	return w < len(b) && b[w]&(1<<(uint(i)&63)) != 0
}

func (b *bitset) or(o bitset) {
	if len(o) > len(*b) {
		*b = append(*b, make([]uint64, len(o)-len(*b))...)
	}
	for i, w := range o {
		(*b)[i] |= w
	}
}

// annot holds the annotations a schema object produced for one instance:
// the evaluated array indices and the evaluated object member positions.
type annot struct {
	items bitset
	props bitset
}

// merge adds the annotations of o to a. Both may be nil.
func (a *annot) merge(o *annot) {
	if a == nil || o == nil {
		return
	}
	a.items.or(o.items)
	a.props.or(o.props)
}
