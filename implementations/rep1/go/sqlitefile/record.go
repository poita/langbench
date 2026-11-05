package sqlitefile

import (
	"encoding/binary"
	"math"
)

// getVarint decodes an SQLite varint from the start of b. It returns the 64-bit
// pattern (reinterpret as int64 for signed values) and the number of bytes
// used, or n == 0 if b is too short.
func getVarint(b []byte) (v uint64, n int) {
	for i := 0; i < 8; i++ {
		if i >= len(b) {
			return 0, 0
		}
		c := b[i]
		v = v<<7 | uint64(c&0x7f)
		if c&0x80 == 0 {
			return v, i + 1
		}
	}
	if len(b) < 9 {
		return 0, 0
	}
	return v<<8 | uint64(b[8]), 9
}

// record is a lazily decoded SQLite record. parse reads only the header; column
// values are decoded on demand straight from the payload. A record is meant to
// be reused from cell to cell without allocating.
type record struct {
	payload []byte
	types   []uint32 // serial type per column
	offs    []int    // body offset per column
}

// parse reads the record header of p. The slices are reused across calls.
func (r *record) parse(p []byte) error {
	r.payload = p
	r.types = r.types[:0]
	r.offs = r.offs[:0]
	h, n := getVarint(p)
	if n == 0 || h > uint64(len(p)) || int(h) < n {
		return ErrCorrupt
	}
	hdr := int(h)
	pos := n
	body := hdr
	for pos < hdr {
		t, m := getVarint(p[pos:hdr])
		if m == 0 || t > math.MaxInt32 || t == 10 || t == 11 {
			return ErrCorrupt
		}
		pos += m
		r.types = append(r.types, uint32(t))
		r.offs = append(r.offs, body)
		body += serialSize(uint32(t))
		if body > len(p) {
			return ErrCorrupt
		}
	}
	return nil
}

// numCols is the number of columns physically present in the record.
func (r *record) numCols() int { return len(r.types) }

func serialSize(t uint32) int {
	switch {
	case t <= 4:
		return int(t)
	case t == 5:
		return 6
	case t == 6 || t == 7:
		return 8
	case t < 12:
		return 0
	}
	return int(t-12) / 2
}

// value decodes column i. Columns beyond the record's length read as NULL.
// TEXT and BLOB values are views into the payload.
func (r *record) value(i int) Value {
	if i >= len(r.types) {
		return Value{}
	}
	t := r.types[i]
	off := r.offs[i]
	p := r.payload
	switch t {
	case 0:
		return Value{}
	case 1:
		return Value{Kind: KindInteger, I: int64(int8(p[off]))}
	case 2:
		return Value{Kind: KindInteger, I: int64(int16(binary.BigEndian.Uint16(p[off:])))}
	case 3:
		u := uint32(p[off])<<16 | uint32(p[off+1])<<8 | uint32(p[off+2])
		return Value{Kind: KindInteger, I: int64(int32(u<<8) >> 8)}
	case 4:
		return Value{Kind: KindInteger, I: int64(int32(binary.BigEndian.Uint32(p[off:])))}
	case 5:
		u := uint64(p[off])<<40 | uint64(p[off+1])<<32 | uint64(binary.BigEndian.Uint32(p[off+2:]))
		return Value{Kind: KindInteger, I: int64(u<<16) >> 16}
	case 6:
		return Value{Kind: KindInteger, I: int64(binary.BigEndian.Uint64(p[off:]))}
	case 7:
		return Value{Kind: KindReal, F: math.Float64frombits(binary.BigEndian.Uint64(p[off:]))}
	case 8:
		return Value{Kind: KindInteger, I: 0}
	case 9:
		return Value{Kind: KindInteger, I: 1}
	}
	size := serialSize(t)
	if t&1 == 0 {
		return Value{Kind: KindBlob, B: p[off : off+size : off+size]}
	}
	return Value{Kind: KindText, B: p[off : off+size : off+size]}
}
