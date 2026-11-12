package qrcode

import "github.com/peteralexander/qrcode/internal/reedsolomon"

// padDataCodewords applies the terminator, bit padding and 0xEC/0x11 pad
// codewords to bb so that exactly dataCodewords codewords result.
func padDataCodewords(bb *bitBuffer, dataCodewords int) []byte {
	capacity := 8 * dataCodewords
	term := capacity - bb.n
	if term > 4 {
		term = 4
	}
	bb.appendBits(0, term)
	if r := bb.n % 8; r != 0 {
		bb.appendBits(0, 8-r)
	}
	out := bb.bytes
	for pad := byte(0xEC); len(out) < dataCodewords; pad ^= 0xEC ^ 0x11 {
		out = append(out, pad)
	}
	return out
}

// addECCAndInterleave splits data into the version's blocks, appends the
// Reed-Solomon ECC of each, and returns the interleaved final codeword
// sequence.
func addECCAndInterleave(data []byte, version int, level Level) []byte {
	nBlocks := numBlocks[level][version-1]
	eccLen := eccPerBlock[level][version-1]
	total := totalCodewords(version)
	nShort := nBlocks - total%nBlocks
	shortLen := total/nBlocks - eccLen // data codewords in a short block

	enc := reedsolomon.NewEncoder(eccLen)
	blocks := make([][]byte, nBlocks)
	ecc := make([][]byte, nBlocks)
	pos := 0
	for i := range blocks {
		n := shortLen
		if i >= nShort {
			n++
		}
		blocks[i] = data[pos : pos+n]
		ecc[i] = enc.Remainder(blocks[i])
		pos += n
	}

	out := make([]byte, 0, total)
	for j := 0; j <= shortLen; j++ {
		for _, b := range blocks {
			if j < len(b) {
				out = append(out, b[j])
			}
		}
	}
	for j := 0; j < eccLen; j++ {
		for _, e := range ecc {
			out = append(out, e[j])
		}
	}
	return out
}
