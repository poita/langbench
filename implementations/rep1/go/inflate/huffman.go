package inflate

import "math/bits"

// A table entry is a uint32:
//
//	bits 0..7   number of bits to consume (0 means "not a code")
//	bit  8      entrySub: entry points at a subtable
//	bits 16..31 symbol, or subtable offset when entrySub is set
//
// For a subtable pointer the length field holds the subtable's index width;
// the root bits are consumed first. Entries inside a subtable hold the code
// length minus the root width.
const (
	entrySub   = 1 << 8
	entryShift = 16
)

// codeRule says how incomplete length sets are treated.
type codeRule uint8

const (
	// ruleComplete accepts only complete codes.
	ruleComplete codeRule = iota
	// ruleSingle also accepts exactly one code of length 1.
	ruleSingle
	// ruleSingleOrEmpty also accepts an empty set.
	ruleSingleOrEmpty
)

// huffTable is a two-level decoding table. The slice storage is reused across
// builds; only the root entries and the subtables in use are rewritten.
type huffTable struct {
	root    uint // root index width R
	entries []uint32
	widths  [1 << litRootBits]uint8 // scratch: subtable width per root prefix
}

// build constructs the table for the given code lengths (each 0..15) with a
// root width of root bits (at most litRootBits), applying rule to decide
// whether an incomplete set is acceptable.
func (t *huffTable) build(lengths []uint8, root uint, rule codeRule) error {
	var count [maxCodeBits + 1]int
	for _, l := range lengths {
		count[l]++
	}
	used := len(lengths) - count[0]
	count[0] = 0

	// Kraft balance.
	left := 1
	for l := 1; l <= maxCodeBits; l++ {
		left = left<<1 - count[l]
		if left < 0 {
			return ErrOverSubscribed
		}
	}
	if left != 0 {
		ok := (rule >= ruleSingle && used == 1 && count[1] == 1) ||
			(rule == ruleSingleOrEmpty && used == 0)
		if !ok {
			return ErrIncompleteCode
		}
	}

	var next [maxCodeBits + 2]uint32
	code := uint32(0)
	for l := 1; l <= maxCodeBits; l++ {
		code = (code + uint32(count[l-1])) << 1
		next[l] = code
	}

	rootSize := 1 << root
	rootMask := uint32(rootSize - 1)

	// Pass 1: width of the subtable needed for each root prefix.
	t.root = root
	widths := t.widths[:rootSize]
	clear(widths)
	nx := next
	hasSub := false
	for _, l := range lengths {
		if l == 0 {
			continue
		}
		c := nx[l]
		nx[l]++
		if uint(l) > root {
			rev := bits.Reverse16(uint16(c)) >> (16 - l)
			p := uint32(rev) & rootMask
			if w := l - uint8(root); w > widths[p] {
				widths[p] = w
			}
			hasSub = true
		}
	}

	// Size and clear the table; place subtable pointers.
	size := rootSize
	if hasSub {
		for _, w := range widths {
			if w > 0 {
				size += 1 << w
			}
		}
	}
	if cap(t.entries) < size {
		t.entries = make([]uint32, size, size+size/2)
	}
	e := t.entries[:size]
	t.entries = e
	clear(e)
	if hasSub {
		off := rootSize
		for p, w := range widths {
			if w > 0 {
				e[p] = uint32(off)<<entryShift | entrySub | uint32(w)
				off += 1 << w
			}
		}
	}

	// Pass 2: fill.
	nx = next
	for sym, l := range lengths {
		if l == 0 {
			continue
		}
		c := nx[l]
		nx[l]++
		rev := uint32(bits.Reverse16(uint16(c)) >> (16 - l))
		if uint(l) <= root {
			ent := uint32(sym)<<entryShift | uint32(l)
			for i := int(rev); i < rootSize; i += 1 << l {
				e[i] = ent
			}
			continue
		}
		ptr := e[rev&rootMask]
		off := int(ptr >> entryShift)
		w := int(ptr & 0xff)
		ent := uint32(sym)<<entryShift | uint32(uint(l)-root)
		step := 1 << (uint(l) - root)
		for i := int(rev >> root); i < 1<<w; i += step {
			e[off+i] = ent
		}
	}
	return nil
}
