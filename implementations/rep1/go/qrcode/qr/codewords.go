package qr

// buildDataCodewords packs the segment, terminator and padding into exactly
// dataCodewords(v, ecl) bytes.
func buildDataCodewords(data []byte, m Mode, v int, ecl ECL) []byte {
	capacity := dataCodewords(v, ecl)
	w := bitWriter{buf: make([]byte, 0, capacity)}
	w.write(modeBits(m), 4)
	w.write(uint32(len(data)), countBits(m, v))
	switch m {
	case Numeric:
		for i := 0; i < len(data); i += 3 {
			j := i + 3
			if j > len(data) {
				j = len(data)
			}
			val := uint32(0)
			for _, b := range data[i:j] {
				val = val*10 + uint32(b-'0')
			}
			w.write(val, [4]uint{0, 4, 7, 10}[j-i])
		}
	case Alphanumeric:
		i := 0
		for ; i+1 < len(data); i += 2 {
			w.write(uint32(alnumVal[data[i]])*45+uint32(alnumVal[data[i+1]]), 11)
		}
		if i < len(data) {
			w.write(uint32(alnumVal[data[i]]), 6)
		}
	default:
		for _, b := range data {
			w.write(uint32(b), 8)
		}
	}
	term := 8*capacity - w.bitLen()
	if term > 4 {
		term = 4
	}
	w.write(0, uint(term))
	w.alignByte()
	for pad := byte(0xEC); len(w.buf) < capacity; pad ^= 0xEC ^ 0x11 {
		w.buf = append(w.buf, pad)
	}
	return w.buf
}

// addECCAndInterleave splits data into blocks, computes Reed-Solomon ECC and
// returns the final interleaved codeword sequence.
func addECCAndInterleave(data []byte, v int, ecl ECL) []byte {
	nb := numBlocks[ecl][v-1]
	e := eccPerBlock[ecl][v-1]
	total := totalCodewords(v)
	shortBlocks := nb - total%nb
	shortLen := total/nb - e

	gen := rsGenerator(e)
	ecc := make([]byte, nb*e)
	blockData := make([][]byte, nb)
	pos := 0
	for i := 0; i < nb; i++ {
		n := shortLen
		if i >= shortBlocks {
			n++
		}
		blockData[i] = data[pos : pos+n]
		pos += n
		rsRemainder(blockData[i], gen, ecc[i*e:(i+1)*e])
	}

	out := make([]byte, 0, total)
	for j := 0; j <= shortLen; j++ {
		for i := 0; i < nb; i++ {
			if j < len(blockData[i]) {
				out = append(out, blockData[i][j])
			}
		}
	}
	for j := 0; j < e; j++ {
		for i := 0; i < nb; i++ {
			out = append(out, ecc[i*e+j])
		}
	}
	return out
}
