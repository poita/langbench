// Package inflate is a table-driven decoder for DEFLATE (RFC 1951) streams
// and the zlib wrapper (RFC 1950).
//
// The decoder is self-terminating: it stops at the end-of-block symbol of the
// final block and reports how many input bytes it used, so several streams
// can be stored back to back (as in a git packfile). The Adler-32 trailer of
// a zlib stream is neither verified nor consumed.
package inflate

import (
	"errors"
	"math/bits"
	"slices"
)

// Errors returned by the decoder.
var (
	ErrHeader    = errors.New("inflate: invalid zlib header")
	ErrTruncated = errors.New("inflate: unexpected end of input")
	ErrCorrupt   = errors.New("inflate: corrupt stream")
)

const (
	rootLit  = 10 // root table width for literal/length codes
	rootDist = 8  // root table width for distance codes
	rootCL   = 7  // code-length code (max code length is 7)
	maxBits  = 15
	maxHint  = 1 << 24 // cap on the initial output allocation
)

// Table entry layout: bits 0-7 code length (0 = not a code), bit 8 set when
// the entry points to a second-level table, bits 16-31 the symbol (or the
// subtable offset).
const subFlag = 1 << 8

var (
	lenBase = [29]uint16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
		35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
	lenExtra = [29]uint8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
		3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
	distBase = [30]uint16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
		257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
	distExtra = [30]uint8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
		7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
	clOrder = [19]uint8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
)

// table is a two-level Huffman lookup table. t[:1<<root] is the root; the
// subtables follow it.
type table struct {
	t    []uint32
	root uint
}

// Decoder holds the reusable Huffman tables. A Decoder may be reused for any
// number of streams but is not safe for concurrent use.
type Decoder struct {
	lit, dist, cl table
	fixedLit      table
	fixedDist     table
	fixedReady    bool

	// scratch space for table construction
	lens    [320]uint8
	codes   [288]uint16
	subW    [1 << rootLit]uint8
	touched []uint16
}

// NewDecoder returns a ready Decoder.
func NewDecoder() *Decoder {
	d := &Decoder{}
	d.lit.root, d.dist.root, d.cl.root = rootLit, rootDist, rootCL
	d.fixedLit.root, d.fixedDist.root = rootLit, rootDist
	return d
}

// build constructs the lookup table for the given code lengths. An
// incomplete code is accepted only when allowIncomplete is set and no code is
// longer than one bit (zlib's rule); over-subscribed codes are always
// rejected.
func (d *Decoder) build(tb *table, lens []uint8, allowIncomplete bool) error {
	var count [maxBits + 1]int
	for _, l := range lens {
		count[l]++
	}
	count[0] = 0
	left := 1
	maxLen := 0
	for l := 1; l <= maxBits; l++ {
		left <<= 1
		left -= count[l]
		if left < 0 {
			return ErrCorrupt // over-subscribed
		}
		if count[l] > 0 {
			maxLen = l
		}
	}
	if left > 0 && !(allowIncomplete && maxLen <= 1) {
		return ErrCorrupt
	}
	var next [maxBits + 1]uint16
	code := uint16(0)
	for l := 1; l <= maxBits; l++ {
		code = (code + uint16(count[l-1])) << 1
		next[l] = code
	}
	root := tb.root
	rsize := 1 << root
	if cap(tb.t) < rsize {
		tb.t = make([]uint32, rsize, rsize*2)
	}
	tb.t = tb.t[:rsize]
	clear(tb.t)

	// pass 1: assign bit-reversed codes and find the subtable widths
	touched := d.touched[:0]
	for sym, l := range lens {
		if l == 0 {
			continue
		}
		c := next[l]
		next[l]++
		rev := bits.Reverse16(c) >> (16 - uint(l))
		d.codes[sym] = rev
		if uint(l) > root {
			idx := rev & uint16(rsize-1)
			w := l - uint8(root)
			if d.subW[idx] == 0 {
				touched = append(touched, idx)
			}
			if w > d.subW[idx] {
				d.subW[idx] = w
			}
		}
	}
	d.touched = touched
	for _, idx := range touched {
		w := uint(d.subW[idx])
		off := len(tb.t)
		need := off + 1<<w
		tb.t = slices.Grow(tb.t, 1<<w)[:need]
		clear(tb.t[off:need])
		tb.t[idx] = uint32(off)<<16 | subFlag | uint32(w)
	}
	// pass 2: fill the tables
	for sym, l := range lens {
		if l == 0 {
			continue
		}
		rev := uint32(d.codes[sym])
		if uint(l) <= root {
			e := uint32(sym)<<16 | uint32(l)
			for i := rev; i < uint32(rsize); i += 1 << l {
				tb.t[i] = e
			}
		} else {
			ptr := tb.t[rev&uint32(rsize-1)]
			off, w := ptr>>16, ptr&0xff
			sl := uint32(l) - uint32(root)
			e := uint32(sym)<<16 | sl
			for i := rev >> root; i < 1<<w; i += 1 << sl {
				tb.t[off+i] = e
			}
		}
	}
	for _, idx := range touched {
		d.subW[idx] = 0
	}
	return nil
}

func (d *Decoder) buildFixed() {
	var l [288]uint8
	for i := range l {
		switch {
		case i < 144:
			l[i] = 8
		case i < 256:
			l[i] = 9
		case i < 280:
			l[i] = 7
		default:
			l[i] = 8
		}
	}
	d.build(&d.fixedLit, l[:], false)
	// 32 distance codes exist in the fixed code; 30 and 31 are rejected
	// when decoded.
	var dl [32]uint8
	for i := range dl {
		dl[i] = 5
	}
	d.build(&d.fixedDist, dl[:], false)
	d.fixedReady = true
}

// bitReader state lives in the decode call to keep it in registers.
type state struct {
	src   []byte
	pos   int
	buf   uint64
	nbits uint
	extra uint // zero bytes appended past the end of src
}

func (s *state) refill() {
	for s.nbits <= 56 {
		if s.pos < len(s.src) {
			s.buf |= uint64(s.src[s.pos]) << s.nbits
			s.pos++
		} else {
			s.extra++
		}
		s.nbits += 8
	}
}

// overrun reports whether bits that do not exist were consumed.
func (s *state) overrun() bool { return s.nbits < s.extra*8 }

func (s *state) take(n uint) uint32 {
	v := uint32(s.buf & (1<<n - 1))
	s.buf >>= n
	s.nbits -= n
	return v
}

func (s *state) sym(tb *table) (uint32, bool) {
	e := tb.t[s.buf&(1<<tb.root-1)]
	if e&subFlag != 0 {
		s.buf >>= tb.root
		s.nbits -= tb.root
		e = tb.t[(e>>16)+uint32(s.buf&(1<<(e&0xff)-1))]
	}
	n := uint(e & 0xff)
	if n == 0 {
		return 0, false
	}
	s.buf >>= n
	s.nbits -= n
	return e >> 16, true
}

// Zlib decodes a zlib stream (RFC 1950) at the start of src. sizeHint is the
// expected decompressed size, used only to size the initial allocation. It
// returns the decompressed data and the number of bytes of src occupied by
// the header and DEFLATE stream (the Adler-32 trailer is not counted).
func (d *Decoder) Zlib(src []byte, sizeHint int) ([]byte, int, error) {
	if len(src) < 2 {
		return nil, 0, ErrTruncated
	}
	cmf, flg := src[0], src[1]
	if cmf&0x0f != 8 || (uint(cmf)*256+uint(flg))%31 != 0 || flg&0x20 != 0 {
		return nil, 0, ErrHeader
	}
	out, n, err := d.Deflate(src[2:], sizeHint)
	return out, n + 2, err
}

// Deflate decodes a raw DEFLATE stream at the start of src and returns the
// output and the number of input bytes used.
func (d *Decoder) Deflate(src []byte, sizeHint int) ([]byte, int, error) {
	if !d.fixedReady {
		d.buildFixed()
	}
	if sizeHint < 0 {
		sizeHint = 0
	}
	if sizeHint > maxHint {
		sizeHint = maxHint
	}
	if sizeHint < 64 {
		sizeHint = 64
	}
	out := make([]byte, 0, sizeHint)
	s := state{src: src}
	for {
		s.refill()
		final := s.take(1)
		typ := s.take(2)
		var err error
		switch typ {
		case 0:
			out, err = d.stored(&s, out)
		case 1:
			out, err = d.decodeCodes(&s, out, &d.fixedLit, &d.fixedDist)
		case 2:
			if err = d.readDynamic(&s); err == nil {
				out, err = d.decodeCodes(&s, out, &d.lit, &d.dist)
			}
		default:
			err = ErrCorrupt
		}
		if err != nil {
			return nil, 0, err
		}
		if s.overrun() {
			return nil, 0, ErrTruncated
		}
		if final == 1 {
			break
		}
	}
	// whole bytes still buffered were not consumed
	used := s.pos - int(s.nbits/8) + int(s.extra)
	return out, used, nil
}

func (d *Decoder) stored(s *state, out []byte) ([]byte, error) {
	s.take(s.nbits & 7)
	whole := int(s.nbits / 8)
	if whole < int(s.extra) {
		return nil, ErrTruncated
	}
	s.pos -= whole - int(s.extra)
	s.buf, s.nbits, s.extra = 0, 0, 0
	if s.pos+4 > len(s.src) {
		return nil, ErrTruncated
	}
	n := int(s.src[s.pos]) | int(s.src[s.pos+1])<<8
	nn := int(s.src[s.pos+2]) | int(s.src[s.pos+3])<<8
	if n != ^nn&0xffff {
		return nil, ErrCorrupt
	}
	s.pos += 4
	if s.pos+n > len(s.src) {
		return nil, ErrTruncated
	}
	out = append(out, s.src[s.pos:s.pos+n]...)
	s.pos += n
	return out, nil
}

func (d *Decoder) readDynamic(s *state) error {
	s.refill()
	hlit := int(s.take(5)) + 257
	hdist := int(s.take(5)) + 1
	hclen := int(s.take(4)) + 4
	if hlit > 286 || hdist > 30 {
		return ErrCorrupt
	}
	var cl [19]uint8
	for i := 0; i < hclen; i++ {
		if s.nbits < 3 {
			s.refill()
		}
		cl[clOrder[i]] = uint8(s.take(3))
	}
	if s.overrun() {
		return ErrTruncated
	}
	if err := d.build(&d.cl, cl[:], false); err != nil {
		return err
	}
	lens := d.lens[:hlit+hdist]
	for i := 0; i < len(lens); {
		s.refill()
		v, ok := s.sym(&d.cl)
		if !ok {
			return ErrCorrupt
		}
		if s.overrun() {
			return ErrTruncated
		}
		if v < 16 {
			lens[i] = uint8(v)
			i++
			continue
		}
		var prev uint8
		var rep int
		switch v {
		case 16:
			if i == 0 {
				return ErrCorrupt
			}
			prev = lens[i-1]
			rep = 3 + int(s.take(2))
		case 17:
			rep = 3 + int(s.take(3))
		default:
			rep = 11 + int(s.take(7))
		}
		if i+rep > len(lens) {
			return ErrCorrupt
		}
		for ; rep > 0; rep-- {
			lens[i] = prev
			i++
		}
	}
	if s.overrun() {
		return ErrTruncated
	}
	if lens[256] == 0 {
		return ErrCorrupt
	}
	if err := d.build(&d.lit, lens[:hlit], true); err != nil {
		return err
	}
	return d.build(&d.dist, lens[hlit:], true)
}

func (d *Decoder) decodeCodes(s *state, out []byte, lit, dist *table) ([]byte, error) {
	for {
		s.refill()
		v, ok := s.sym(lit)
		if !ok {
			return nil, ErrCorrupt
		}
		if s.overrun() {
			return nil, ErrTruncated
		}
		if v < 256 {
			out = append(out, byte(v))
			continue
		}
		if v == 256 {
			return out, nil
		}
		v -= 257
		if v >= 29 {
			return nil, ErrCorrupt
		}
		length := int(lenBase[v]) + int(s.take(uint(lenExtra[v])))
		dv, ok := s.sym(dist)
		if !ok || dv >= 30 {
			return nil, ErrCorrupt
		}
		off := int(distBase[dv]) + int(s.take(uint(distExtra[dv])))
		if s.overrun() {
			return nil, ErrTruncated
		}
		n := len(out)
		if off > n {
			return nil, ErrCorrupt
		}
		out = copyMatch(out, off, length)
	}
}

// copyMatch appends length bytes copied from off bytes back in out. When
// off < length the source overlaps the destination and the copy repeats the
// last off bytes; each round at least doubles the available source.
func copyMatch(out []byte, off, length int) []byte {
	src := len(out) - off
	for length > 0 {
		k := min(length, len(out)-src)
		out = append(out, out[src:src+k]...)
		length -= k
	}
	return out
}
