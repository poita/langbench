// Package crc implements the CRC-32 checksum used throughout Tessera
// (reflected polynomial 0xEDB88320, initial value and final XOR 0xFFFFFFFF).
//
// It is a from-scratch, table-driven implementation; the standard library's
// hash/crc32 is deliberately not used.
package crc

const poly = 0xEDB88320

var table = makeTable()

func makeTable() [256]uint32 {
	var t [256]uint32
	for i := range t {
		c := uint32(i)
		for k := 0; k < 8; k++ {
			if c&1 != 0 {
				c = (c >> 1) ^ poly
			} else {
				c >>= 1
			}
		}
		t[i] = c
	}
	return t
}

// Update returns the checksum of the concatenation of the data that sum was
// computed over and p. Update(0, p) equals Checksum(p), so checksums of
// several pieces can be chained without concatenating them.
func Update(sum uint32, p []byte) uint32 {
	c := ^sum
	for _, b := range p {
		c = table[byte(c)^b] ^ (c >> 8)
	}
	return ^c
}

// Checksum returns the CRC-32 of p.
func Checksum(p []byte) uint32 { return Update(0, p) }
