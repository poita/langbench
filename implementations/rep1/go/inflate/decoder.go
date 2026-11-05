package inflate

import "sync"

// Decoder decodes DEFLATE streams. It owns the Huffman table buffers used for
// dynamic blocks, so reusing one Decoder for many streams avoids reallocating
// them. A Decoder must not be used by several goroutines at once.
type Decoder struct {
	br  bitReader
	out []byte // output buffer; len(out) is its capacity, o is the fill level
	o   int

	lit, dist, cl huffTable
	lengths       [maxLitLen + maxDist]uint8
}

// maxInitialOutput caps the output buffer preallocated from the input size.
const maxInitialOutput = 32 << 20

// NewDecoder returns a ready-to-use Decoder.
func NewDecoder() *Decoder { return &Decoder{} }

// Decode decompresses the raw DEFLATE stream src and returns the result. The
// returned slice is freshly allocated and owned by the caller. On error the
// returned slice is nil and the error is one of the Err* values.
func Decode(src []byte) ([]byte, error) {
	return NewDecoder().Decode(src)
}

// Decode decompresses the raw DEFLATE stream src; see the package-level
// Decode.
func (d *Decoder) Decode(src []byte) ([]byte, error) {
	d.br.reset(src)
	n := 4 * len(src)
	switch {
	case n < 4096:
		n = 4096
	case n > maxInitialOutput:
		n = maxInitialOutput
	}
	d.out = make([]byte, n)
	d.o = 0
	defer func() { d.out, d.br = nil, bitReader{} }()

	for {
		d.br.refill()
		hdr := d.br.take(3)
		if d.br.overrun() {
			return nil, ErrTruncated
		}
		var err error
		switch hdr >> 1 {
		case 0:
			err = d.stored()
		case 1:
			lit, dist := fixedTables()
			err = d.codes(lit, dist)
		case 2:
			err = d.dynamic()
		default:
			err = ErrBlockType
		}
		if err != nil {
			return nil, err
		}
		if d.br.overrun() {
			return nil, ErrTruncated
		}
		if hdr&1 == 1 {
			break
		}
	}
	// Rounding the consumed bits up to whole bytes must reach the end.
	if (d.br.consumed()+7)/8 != len(src) {
		return nil, ErrTrailingData
	}
	return d.out[:d.o:d.o], nil
}

// growTo returns a buffer, holding the first o bytes of out, with room for at
// least need more bytes.
func growTo(out []byte, o, need int) []byte {
	n := 2 * len(out)
	if n < o+need {
		n = o + need
	}
	nb := make([]byte, n)
	copy(nb, out[:o])
	return nb
}

// stored decodes a stored block; the 3 header bits are already consumed.
func (d *Decoder) stored() error {
	br := &d.br
	br.alignToByte()
	br.refill()
	length := br.take(16)
	nlength := br.take(16)
	if br.overrun() {
		return ErrTruncated
	}
	if length^nlength != 0xffff {
		return ErrStoredLength
	}
	start := br.consumed() / 8
	end := start + int(length)
	if end > len(br.data) {
		return ErrTruncated
	}
	if d.o+int(length) > len(d.out) {
		d.out = growTo(d.out, d.o, int(length))
	}
	d.o += copy(d.out[d.o:], br.data[start:end])
	br.seekByte(end)
	return nil
}

// dynamic decodes a dynamic-Huffman block; the 3 header bits are consumed.
func (d *Decoder) dynamic() error {
	br := &d.br
	br.refill()
	nlit := int(br.take(5)) + 257
	ndist := int(br.take(5)) + 1
	nclen := int(br.take(4)) + 4
	if nlit > maxLitLen || ndist > maxDist {
		return ErrTooManyCodes
	}

	var cl [numCodeLen]uint8
	for i := 0; i < nclen; i++ {
		br.refill()
		cl[codeLengthOrder[i]] = uint8(br.take(3))
	}
	if br.overrun() {
		return ErrTruncated
	}
	if err := d.cl.build(cl[:], clRootBits, ruleComplete); err != nil {
		return err
	}

	total := nlit + ndist
	lengths := d.lengths[:total]
	clTab := d.cl.entries
	for i := 0; i < total; {
		br.refill()
		e := clTab[br.buf&(1<<clRootBits-1)]
		l := uint(e & 0xff)
		if l == 0 {
			return ErrInvalidCode
		}
		br.take(l)
		sym := e >> entryShift
		if sym < 16 {
			lengths[i] = uint8(sym)
			i++
			continue
		}
		var rep int
		var val uint8
		switch sym {
		case 16:
			if i == 0 {
				return ErrBadRepeat
			}
			val = lengths[i-1]
			rep = 3 + int(br.take(2))
		case 17:
			rep = 3 + int(br.take(3))
		default: // 18
			rep = 11 + int(br.take(7))
		}
		if i+rep > total {
			return ErrBadRepeat
		}
		for end := i + rep; i < end; i++ {
			lengths[i] = val
		}
	}
	if br.overrun() {
		return ErrTruncated
	}

	if lengths[endOfBlock] == 0 {
		return ErrMissingEndOfBlock
	}
	if err := d.lit.build(lengths[:nlit], litRootBits, ruleSingle); err != nil {
		return err
	}
	if err := d.dist.build(lengths[nlit:], distRootBits, ruleSingleOrEmpty); err != nil {
		return err
	}
	return d.codes(&d.lit, &d.dist)
}

// codes decodes the symbols of a compressed block using the given tables.
func (d *Decoder) codes(lit, dist *huffTable) error {
	br := &d.br
	data := br.data
	buf, n, pos := br.buf, br.n, br.pos
	out, o := d.out, d.o

	litTab, litRoot := lit.entries, lit.root
	litMask := uint64(1)<<litRoot - 1
	distTab, distRoot := dist.entries, dist.root
	distMask := uint64(1)<<distRoot - 1

	var err error
	for {
		// Refill to >= 56 bits: enough for a length code (15), its extra bits
		// (5), a distance code (15) and its extra bits (13).
		if pos+8 <= len(data) {
			buf |= le64(data[pos:]) << n
			pos += int(63-n) >> 3
			n |= 56
		} else {
			br.buf, br.n, br.pos = buf, n, pos
			br.refillSlow()
			buf, n, pos = br.buf, br.n, br.pos
			if br.overrun() {
				err = ErrTruncated
				break
			}
		}

		e := litTab[buf&litMask]
		if e&entrySub != 0 {
			buf >>= litRoot
			n -= litRoot
			e = litTab[int(e>>entryShift)+int(buf&(1<<(e&0xff)-1))]
		}
		l := uint(e & 0xff)
		if l == 0 {
			err = ErrInvalidCode
			break
		}
		buf >>= l
		n -= l
		sym := int(e >> entryShift)

		if sym < endOfBlock {
			if o == len(out) {
				out = growTo(out, o, 1)
			}
			out[o] = byte(sym)
			o++
			continue
		}
		if sym == endOfBlock {
			break
		}
		if sym > lastLenSym {
			err = ErrInvalidSymbol
			break
		}

		sym -= firstLenSym
		eb := uint(lengthExtra[sym])
		length := int(lengthBase[sym]) + int(buf&(1<<eb-1))
		buf >>= eb
		n -= eb

		e = distTab[buf&distMask]
		if e&entrySub != 0 {
			buf >>= distRoot
			n -= distRoot
			e = distTab[int(e>>entryShift)+int(buf&(1<<(e&0xff)-1))]
		}
		l = uint(e & 0xff)
		if l == 0 {
			err = ErrInvalidCode
			break
		}
		buf >>= l
		n -= l
		sym = int(e >> entryShift)
		if sym > lastDistSym {
			err = ErrInvalidSymbol
			break
		}
		eb = uint(distExtra[sym])
		distance := int(distBase[sym]) + int(buf&(1<<eb-1))
		buf >>= eb
		n -= eb

		if distance > o {
			err = ErrDistance
			break
		}
		if o+length > len(out) {
			out = growTo(out, o, length)
		}
		// Copy in chunks: each pass copies everything between the source and
		// the write position, so overlapping copies (distance < length)
		// replicate the pattern and the copied region doubles every time.
		src := o - distance
		end := o + length
		for o < end {
			o += copy(out[o:end], out[src:o])
		}
	}

	br.buf, br.n, br.pos = buf, n, pos
	d.out, d.o = out, o
	return err
}

// Fixed-code tables (RFC 1951 section 3.2.6), built once and shared.
var (
	fixedOnce sync.Once
	fixedLit  huffTable
	fixedDist huffTable
)

func fixedTables() (lit, dist *huffTable) {
	fixedOnce.Do(func() {
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
		var dl [32]uint8
		for i := range dl {
			dl[i] = 5
		}
		if err := fixedLit.build(l[:], litRootBits, ruleComplete); err != nil {
			panic(err)
		}
		if err := fixedDist.build(dl[:], distRootBits, ruleComplete); err != nil {
			panic(err)
		}
	})
	return &fixedLit, &fixedDist
}
