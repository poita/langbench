// Package checksum implements the Adler-32 checksum.
package checksum

import "fmt"

const mod = 65521

// Adler32 returns the Adler-32 checksum of b.
func Adler32(b []byte) uint32 {
	a, s := uint32(1), uint32(0)
	for _, x := range b {
		a = (a + uint32(x)) % mod
		s = (s + a) % mod
	}
	return s<<16 | a
}

// Adler32Hex returns the checksum as exactly eight lower-case hex digits.
func Adler32Hex(b []byte) string { return fmt.Sprintf("%08x", Adler32(b)) }
