// Package crc implements the CRC-32 checksum used throughout Tessera.
//
// It is the reflected CRC-32 with polynomial 0xEDB88320, initial value
// 0xFFFFFFFF and a final XOR of 0xFFFFFFFF (the same parameters as IEEE 802.3),
// implemented here from scratch with a 256-entry lookup table.
package crc

// Poly is the reflected CRC-32 polynomial.
const Poly uint32 = 0xEDB88320

var table = makeTable()

func makeTable() (t [256]uint32) {
	for i := range t {
		c := uint32(i)
		for k := 0; k < 8; k++ {
			if c&1 != 0 {
				c = (c >> 1) ^ Poly
			} else {
				c >>= 1
			}
		}
		t[i] = c
	}
	return t
}

// Update continues a running checksum with data. The running value is the
// finalised CRC of the bytes seen so far, so Update(0, p) equals Checksum(p)
// and Update(Checksum(a), b) equals Checksum(a||b).
func Update(crc uint32, data []byte) uint32 {
	c := ^crc
	for _, b := range data {
		c = table[byte(c)^b] ^ (c >> 8)
	}
	return ^c
}

// Checksum returns the CRC-32 of data.
func Checksum(data []byte) uint32 {
	return Update(0, data)
}
