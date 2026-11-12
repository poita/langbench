// Package inflate implements a decoder for DEFLATE (RFC 1951) streams and the
// zlib container (RFC 1950) around them.
//
// The decoder works on in-memory byte slices and reports how many input bytes
// a stream occupied, which is what a packfile reader needs: objects in a pack
// are stored back to back and the end of one is found by decoding it.
package inflate

import (
	"errors"
	"fmt"
	"sync"
)

// ErrCorrupt is wrapped by every error caused by malformed input.
var ErrCorrupt = errors.New("inflate: corrupt stream")

func corrupt(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrCorrupt, fmt.Sprintf(format, args...))
}

const (
	maxBits    = 15
	maxLitLen  = 286
	maxDist    = 30
	maxCodeLen = 19
)

// Zlib decodes the zlib stream at the start of src. It returns the
// decompressed bytes and the number of bytes of src the stream occupied
// (header, DEFLATE data and Adler-32 trailer). Bytes after the stream are not
// examined. sizeHint, if positive, pre-sizes the output buffer.
//
// The header must name the deflate method, pass the header check and not use a
// preset dictionary. The Adler-32 trailer is verified.
func Zlib(src []byte, sizeHint int) (out []byte, n int, err error) {
	if len(src) < 2 {
		return nil, 0, corrupt("truncated zlib header")
	}
	cmf, flg := src[0], src[1]
	if cmf&0x0f != 8 || (uint(cmf)<<8|uint(flg))%31 != 0 || flg&0x20 != 0 {
		return nil, 0, corrupt("bad zlib header %02x%02x", cmf, flg)
	}
	out, used, err := Deflate(src[2:], sizeHint)
	if err != nil {
		return nil, 0, err
	}
	pos := 2 + used
	if len(src) < pos+4 {
		return nil, 0, corrupt("truncated zlib trailer")
	}
	want := uint32(src[pos])<<24 | uint32(src[pos+1])<<16 | uint32(src[pos+2])<<8 | uint32(src[pos+3])
	if adler32(out) != want {
		return nil, 0, corrupt("adler-32 mismatch")
	}
	return out, pos + 4, nil
}

// Deflate decodes the raw DEFLATE stream at the start of src. It returns the
// decompressed bytes and the number of bytes of src consumed, i.e. up to and
// including the byte holding the last bit of the final block.
func Deflate(src []byte, sizeHint int) (out []byte, n int, err error) {
	d := &decoder{src: src}
	if sizeHint > 0 && sizeHint < 1<<30 {
		d.out = make([]byte, 0, sizeHint)
	}
	for {
		final, err := d.bits(1)
		if err != nil {
			return nil, 0, err
		}
		typ, err := d.bits(2)
		if err != nil {
			return nil, 0, err
		}
		switch typ {
		case 0:
			err = d.stored()
		case 1:
			fixedOnce()
			err = d.codes(&fixedLit, &fixedDist)
		case 2:
			err = d.dynamic()
		default:
			err = corrupt("reserved block type")
		}
		if err != nil {
			return nil, 0, err
		}
		if final == 1 {
			return d.out, d.pos, nil
		}
	}
}

func adler32(p []byte) uint32 {
	const mod = 65521
	a, b := uint32(1), uint32(0)
	for len(p) > 0 {
		n := len(p)
		if n > 5552 {
			n = 5552
		}
		for _, c := range p[:n] {
			a += uint32(c)
			b += a
		}
		a %= mod
		b %= mod
		p = p[n:]
	}
	return b<<16 | a
}

type decoder struct {
	src    []byte
	pos    int
	bitbuf uint32
	bitcnt uint
	out    []byte
}

func (d *decoder) bits(n uint) (int, error) {
	for d.bitcnt < n {
		if d.pos >= len(d.src) {
			return 0, corrupt("unexpected end of input")
		}
		d.bitbuf |= uint32(d.src[d.pos]) << d.bitcnt
		d.pos++
		d.bitcnt += 8
	}
	v := d.bitbuf & (1<<n - 1)
	d.bitbuf >>= n
	d.bitcnt -= n
	return int(v), nil
}

func (d *decoder) stored() error {
	d.bitbuf, d.bitcnt = 0, 0 // discard the rest of the current byte
	if d.pos+4 > len(d.src) {
		return corrupt("truncated stored block header")
	}
	n := int(d.src[d.pos]) | int(d.src[d.pos+1])<<8
	nn := int(d.src[d.pos+2]) | int(d.src[d.pos+3])<<8
	if n != ^nn&0xffff {
		return corrupt("stored block length mismatch")
	}
	d.pos += 4
	if d.pos+n > len(d.src) {
		return corrupt("truncated stored block")
	}
	d.out = append(d.out, d.src[d.pos:d.pos+n]...)
	d.pos += n
	return nil
}

// huffman is a canonical Huffman decoding table in the style of zlib's puff.
type huffman struct {
	count  [maxBits + 1]uint16 // number of codes of each length
	symbol []uint16            // symbols ordered by code
}

// build constructs a table from code lengths. The returned left is 0 for a
// complete code, positive for an incomplete one and negative if the code is
// over-subscribed.
func (h *huffman) build(lengths []uint8) (left int) {
	h.count = [maxBits + 1]uint16{}
	for _, l := range lengths {
		h.count[l]++
	}
	if int(h.count[0]) == len(lengths) {
		h.symbol = h.symbol[:0]
		return 0
	}
	left = 1
	for l := 1; l <= maxBits; l++ {
		left <<= 1
		left -= int(h.count[l])
		if left < 0 {
			return left
		}
	}
	var offs [maxBits + 2]uint16
	for l := 1; l <= maxBits; l++ {
		offs[l+1] = offs[l] + h.count[l]
	}
	h.symbol = make([]uint16, len(lengths))
	for sym, l := range lengths {
		if l != 0 {
			h.symbol[offs[l]] = uint16(sym)
			offs[l]++
		}
	}
	return left
}

func (d *decoder) decode(h *huffman) (int, error) {
	code, first, index := 0, 0, 0
	for l := 1; l <= maxBits; l++ {
		if d.bitcnt == 0 {
			if d.pos >= len(d.src) {
				return 0, corrupt("unexpected end of input")
			}
			d.bitbuf = uint32(d.src[d.pos])
			d.pos++
			d.bitcnt = 8
		}
		code |= int(d.bitbuf & 1)
		d.bitbuf >>= 1
		d.bitcnt--
		count := int(h.count[l])
		if code-count < first {
			return int(h.symbol[index+(code-first)]), nil
		}
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return 0, corrupt("invalid Huffman code")
}

var (
	lenBase   = [29]uint16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
	lenExtra  = [29]uint8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
	distBase  = [30]uint16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
	distExtra = [30]uint8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
	clOrder   = [maxCodeLen]uint8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
)

var (
	fixedLit, fixedDist huffman
	fixedBuild          sync.Once
)

func fixedOnce() { fixedBuild.Do(buildFixed) }

func buildFixed() {
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
	fixedLit.build(l[:])
	var dl [maxDist]uint8
	for i := range dl {
		dl[i] = 5
	}
	fixedDist.build(dl[:])
}

func (d *decoder) codes(lit, dist *huffman) error {
	for {
		sym, err := d.decode(lit)
		if err != nil {
			return err
		}
		switch {
		case sym < 256:
			d.out = append(d.out, byte(sym))
		case sym == 256:
			return nil
		default:
			sym -= 257
			if sym >= 29 {
				return corrupt("invalid length symbol")
			}
			eb, err := d.bits(uint(lenExtra[sym]))
			if err != nil {
				return err
			}
			length := int(lenBase[sym]) + eb
			ds, err := d.decode(dist)
			if err != nil {
				return err
			}
			if ds >= maxDist {
				return corrupt("invalid distance symbol")
			}
			eb, err = d.bits(uint(distExtra[ds]))
			if err != nil {
				return err
			}
			distance := int(distBase[ds]) + eb
			if distance > len(d.out) {
				return corrupt("distance too far back")
			}
			start := len(d.out) - distance
			if distance >= length {
				d.out = append(d.out, d.out[start:start+length]...)
			} else {
				for i := 0; i < length; i++ {
					d.out = append(d.out, d.out[start+i])
				}
			}
		}
	}
}

func (d *decoder) dynamic() error {
	v, err := d.bits(5)
	if err != nil {
		return err
	}
	nlen := v + 257
	if v, err = d.bits(5); err != nil {
		return err
	}
	ndist := v + 1
	if v, err = d.bits(4); err != nil {
		return err
	}
	ncode := v + 4
	if nlen > maxLitLen || ndist > maxDist {
		return corrupt("too many length or distance codes")
	}
	var lengths [maxLitLen + maxDist]uint8
	for i := 0; i < ncode; i++ {
		if v, err = d.bits(3); err != nil {
			return err
		}
		lengths[clOrder[i]] = uint8(v)
	}
	var cl huffman
	if cl.build(lengths[:maxCodeLen]) != 0 {
		return corrupt("incomplete or over-subscribed code length code")
	}
	lengths = [maxLitLen + maxDist]uint8{}
	for i := 0; i < nlen+ndist; {
		sym, err := d.decode(&cl)
		if err != nil {
			return err
		}
		if sym < 16 {
			lengths[i] = uint8(sym)
			i++
			continue
		}
		var prev uint8
		var rep int
		switch sym {
		case 16:
			if i == 0 {
				return corrupt("repeat with no previous length")
			}
			prev = lengths[i-1]
			if rep, err = d.bits(2); err != nil {
				return err
			}
			rep += 3
		case 17:
			if rep, err = d.bits(3); err != nil {
				return err
			}
			rep += 3
		default:
			if rep, err = d.bits(7); err != nil {
				return err
			}
			rep += 11
		}
		if i+rep > nlen+ndist {
			return corrupt("too many code lengths")
		}
		for ; rep > 0; rep-- {
			lengths[i] = prev
			i++
		}
	}
	if lengths[256] == 0 {
		return corrupt("no end-of-block code")
	}
	var lit, dist huffman
	left := lit.build(lengths[:nlen])
	if left < 0 || (left > 0 && nlen != int(lit.count[0])+int(lit.count[1])) {
		return corrupt("bad literal/length code")
	}
	left = dist.build(lengths[nlen : nlen+ndist])
	if left < 0 || (left > 0 && ndist != int(dist.count[0])+int(dist.count[1])) {
		return corrupt("bad distance code")
	}
	return d.codes(&lit, &dist)
}
