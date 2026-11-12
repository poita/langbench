package inflate

import "sync"

// Decoder decodes DEFLATE streams. The zero value is ready to use. A Decoder
// keeps its Huffman table buffers between calls so that decoding many streams
// does not reallocate them; it must not be used concurrently.
type Decoder struct {
	lit, dist, cl huffTable
	lengths       [maxLitLenSyms + maxDistSyms]uint8
}

// Decode decompresses the raw DEFLATE stream src and returns the output.
// src must contain exactly one complete stream: truncated input and whole
// bytes after the final block are errors.
func Decode(src []byte) ([]byte, error) {
	var d Decoder
	return d.Append(nil, src)
}

// Decode is like the package-level Decode but reuses the Decoder's buffers.
func (d *Decoder) Decode(src []byte) ([]byte, error) {
	return d.Append(nil, src)
}

// Append decompresses src and appends the output to dst, returning the
// extended slice. Back-references may only reach bytes produced by this call,
// not the existing contents of dst. On error the returned slice is dst
// unchanged in length.
func (d *Decoder) Append(dst, src []byte) ([]byte, error) {
	out, err := d.decode(dst, src)
	if err != nil {
		return dst, err
	}
	return out, nil
}

var (
	fixedOnce          sync.Once
	fixedLit, fixedDst huffTable
)

func fixedTables() (*huffTable, *huffTable) {
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
		fixedLit.build(l[:], litRootBits)
		var dl [32]uint8
		for i := range dl {
			dl[i] = 5
		}
		fixedDst.build(dl[:], distRootBits)
	})
	return &fixedLit, &fixedDst
}

func (d *Decoder) decode(out, src []byte) ([]byte, error) {
	br := newBitReader(src)
	base := len(out)
	for {
		hdr, err := br.bits(3)
		if err != nil {
			return out, err
		}
		final := hdr&1 != 0
		switch hdr >> 1 {
		case 0:
			out, err = storedBlock(out, &br)
		case 1:
			lit, dist := fixedTables()
			out, err = inflateBlock(out, base, &br, lit, dist)
		case 2:
			if err = d.readDynamicTables(&br); err == nil {
				out, err = inflateBlock(out, base, &br, &d.lit, &d.dist)
			}
		default:
			err = ErrBlockType
		}
		if err != nil {
			return out, err
		}
		if final {
			break
		}
	}
	if br.remainingBytes() != 0 {
		return out, ErrTrailingData
	}
	return out, nil
}

// storedBlock copies a stored block (header bits already consumed).
func storedBlock(out []byte, br *bitReader) ([]byte, error) {
	br.alignToByte()
	if len(br.data)-br.pos < 4 {
		return out, ErrTruncated
	}
	p := br.data[br.pos:]
	n := int(p[0]) | int(p[1])<<8
	nn := int(p[2]) | int(p[3])<<8
	if n^nn != 0xffff {
		return out, ErrStoredLength
	}
	br.pos += 4
	if len(br.data)-br.pos < n {
		return out, ErrTruncated
	}
	out = append(out, br.data[br.pos:br.pos+n]...)
	br.pos += n
	return out, nil
}

// readDynamicTables reads a dynamic block header and builds d.lit and d.dist.
func (d *Decoder) readDynamicTables(br *bitReader) error {
	v, err := br.bits(14)
	if err != nil {
		return err
	}
	nlit := int(v&31) + 257
	ndist := int(v>>5&31) + 1
	nclen := int(v>>10) + 4
	if nlit > maxLitLenSyms || ndist > maxDistSyms {
		return ErrHeaderCounts
	}

	var cl [numCLSyms]uint8
	for i := 0; i < nclen; i++ {
		x, err := br.bits(3)
		if err != nil {
			return err
		}
		cl[codeLengthOrder[i]] = uint8(x)
	}
	if d.cl.build(cl[:], clRootBits).kind != codeComplete {
		return ErrCodeLengths
	}

	total := nlit + ndist
	lengths := d.lengths[:total]
	for i := 0; i < total; {
		br.refill()
		sym, err := d.cl.decode(br)
		if err != nil {
			return err
		}
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
				return ErrRepeat
			}
			val = lengths[i-1]
			x, err := br.bits(2)
			if err != nil {
				return err
			}
			rep = 3 + int(x)
		case 17:
			x, err := br.bits(3)
			if err != nil {
				return err
			}
			rep = 3 + int(x)
		default: // 18
			x, err := br.bits(7)
			if err != nil {
				return err
			}
			rep = 11 + int(x)
		}
		if rep > total-i {
			return ErrRepeat
		}
		for ; rep > 0; rep-- {
			lengths[i] = val
			i++
		}
	}

	litLens := lengths[:nlit]
	if litLens[endOfBlock] == 0 {
		return ErrCodeLengths
	}
	shape := d.lit.build(litLens, litRootBits)
	if shape.kind == codeOversubscribed ||
		(shape.kind == codeIncomplete && !shape.singleBit()) {
		return ErrCodeLengths
	}
	shape = d.dist.build(lengths[nlit:], distRootBits)
	if shape.kind == codeOversubscribed ||
		(shape.kind == codeIncomplete && !shape.singleBit()) {
		return ErrCodeLengths
	}
	return nil
}

// inflateBlock decodes the symbols of one compressed block. base is the
// offset in out where the stream's output begins.
func inflateBlock(out []byte, base int, br *bitReader, lit, dist *huffTable) ([]byte, error) {
	for {
		br.refill()
		sym, err := lit.decode(br)
		if err != nil {
			return out, err
		}
		if sym < endOfBlock {
			out = append(out, byte(sym))
			continue
		}
		if sym == endOfBlock {
			return out, nil
		}
		sym -= 257
		if sym >= len(lengthBase) {
			return out, ErrInvalidSymbol
		}
		length := int(lengthBase[sym])
		if eb := uint(lengthExtra[sym]); eb != 0 {
			x, err := br.bits(eb)
			if err != nil {
				return out, err
			}
			length += int(x)
		}

		br.refill()
		dsym, err := dist.decode(br)
		if err != nil {
			return out, err
		}
		if dsym >= len(distBase) {
			return out, ErrInvalidSymbol
		}
		distance := int(distBase[dsym])
		if eb := uint(distExtra[dsym]); eb != 0 {
			x, err := br.bits(eb)
			if err != nil {
				return out, err
			}
			distance += int(x)
		}
		if distance > len(out)-base {
			return out, ErrDistance
		}
		out = appendCopy(out, distance, length)
	}
}

// appendCopy appends length bytes copied from distance bytes back, where the
// source may overlap the bytes being written.
func appendCopy(out []byte, distance, length int) []byte {
	start := len(out) - distance
	if distance >= length {
		return append(out, out[start:start+length]...)
	}
	// Overlapping: the output from start onwards has period distance, so
	// repeatedly appending what is already there (a multiple of distance
	// bytes) extends it correctly.
	for length > 0 {
		chunk := min(length, len(out)-start)
		out = append(out, out[start:start+chunk]...)
		length -= chunk
	}
	return out
}
