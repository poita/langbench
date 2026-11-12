package inflate

import "math/bits"

// Table entry layout (uint32):
//
//	bits 16..31  symbol (direct entry) or offset of the subtable (link entry)
//	bit  8       link flag
//	bits 0..3    code length in bits (direct entry) or subtable index width
//	             (link entry)
//
// An all-zero entry marks a bit pattern that is not a code.
const linkFlag = 1 << 8

// codeKind classifies a set of code lengths by its Kraft sum.
type codeKind uint8

const (
	codeEmpty          codeKind = iota // no symbol has a code
	codeComplete                       // Kraft sum is exactly 1
	codeIncomplete                     // Kraft sum is below 1
	codeOversubscribed                 // Kraft sum is above 1
)

// codeShape summarises a set of code lengths.
type codeShape struct {
	kind   codeKind
	used   int // number of symbols with a nonzero length
	count1 int // number of symbols with length 1
}

// singleBit reports whether the set is exactly one code of length 1.
func (s codeShape) singleBit() bool { return s.used == 1 && s.count1 == 1 }

// huffTable is a two-level lookup table for one canonical Huffman code.
// The first 1<<rootBits entries are indexed by the next rootBits stream bits;
// codes longer than rootBits chain to a subtable appended after the root.
type huffTable struct {
	rootBits uint
	entries  []uint32
	subWidth []uint8 // scratch: subtable width per root slot
}

// build constructs the table for the given code lengths (0 = unused) and
// returns the shape of the code. Over-subscribed codes leave the table
// unusable. Work is O(len(lengths) + 2^rootBits).
func (t *huffTable) build(lengths []uint8, rootBits uint) codeShape {
	t.rootBits = rootBits
	var count [maxCodeLen + 1]int
	for _, l := range lengths {
		count[l]++
	}
	shape := codeShape{used: len(lengths) - count[0], count1: count[1]}

	left := 1
	for l := 1; l <= maxCodeLen; l++ {
		left = left<<1 - count[l]
		if left < 0 {
			shape.kind = codeOversubscribed
			return shape
		}
	}
	switch {
	case shape.used == 0:
		shape.kind = codeEmpty
	case left == 0:
		shape.kind = codeComplete
	default:
		shape.kind = codeIncomplete
	}

	// Canonical code assignment; store each code bit-reversed because the
	// stream delivers Huffman codes starting with their first bit.
	count[0] = 0
	var next [maxCodeLen + 2]uint32
	code := uint32(0)
	for l := 1; l <= maxCodeLen; l++ {
		code = (code + uint32(count[l-1])) << 1
		next[l] = code
	}
	var rev [288]uint16
	if len(lengths) > len(rev) {
		panic("inflate: too many symbols")
	}
	rootSize := 1 << rootBits
	rootMask := uint32(rootSize - 1)
	if cap(t.entries) < rootSize {
		t.entries = make([]uint32, rootSize, 2*rootSize)
	}
	t.entries = t.entries[:rootSize]
	clear(t.entries)
	if cap(t.subWidth) < rootSize {
		t.subWidth = make([]uint8, rootSize)
	}
	t.subWidth = t.subWidth[:rootSize]
	clear(t.subWidth)

	hasLong := false
	for sym, l := range lengths {
		if l == 0 {
			continue
		}
		r := bits.Reverse16(uint16(next[l])) >> (16 - uint(l))
		next[l]++
		rev[sym] = r
		if uint(l) <= rootBits {
			e := uint32(sym)<<16 | uint32(l)
			for i := int(r); i < rootSize; i += 1 << l {
				t.entries[i] = e
			}
		} else {
			hasLong = true
			p := uint32(r) & rootMask
			if w := l - uint8(rootBits); w > t.subWidth[p] {
				t.subWidth[p] = w
			}
		}
	}
	if !hasLong {
		return shape
	}

	// Allocate one subtable per root slot that has long codes.
	for p := 0; p < rootSize; p++ {
		if w := t.subWidth[p]; w != 0 {
			off := len(t.entries)
			t.entries = append(t.entries, make([]uint32, 1<<w)...)
			t.entries[p] = uint32(off)<<16 | linkFlag | uint32(w)
		}
	}
	for sym, l := range lengths {
		if uint(l) <= rootBits {
			continue
		}
		r := uint32(rev[sym])
		link := t.entries[r&rootMask]
		off := int(link >> 16)
		w := uint(link & 0xf)
		e := uint32(sym)<<16 | uint32(l)
		for i := int(r >> rootBits); i < 1<<w; i += 1 << (uint(l) - rootBits) {
			t.entries[off+i] = e
		}
	}
	return shape
}

// decode reads one symbol. The caller must have called br.refill so that
// enough bits are buffered (peeking beyond the end of the data sees zeros).
func (t *huffTable) decode(br *bitReader) (int, error) {
	e := t.entries[br.buf&(1<<t.rootBits-1)]
	if e&linkFlag != 0 {
		w := uint(e & 0xf)
		idx := (br.buf >> t.rootBits) & (1<<w - 1)
		e = t.entries[int(e>>16)+int(idx)]
	}
	n := uint(e & 0xf)
	if n == 0 {
		return 0, ErrInvalidCode
	}
	if err := br.consume(n); err != nil {
		return 0, err
	}
	return int(e >> 16), nil
}
