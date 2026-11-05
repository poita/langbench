// Package checksum implements the Adler-32 checksum.
package checksum

const (
	mod = 65521
	// nmax is the largest n such that 255*n*(n+1)/2 + (n+1)*(mod-1) fits in
	// 32 bits, so the sums need to be reduced only once per nmax bytes.
	nmax = 5552
)

// Adler32 returns the Adler-32 checksum of b: a = 1 + sum of bytes and
// b = sum of the running values of a, both modulo 65521, packed as b<<16 | a.
func Adler32(data []byte) uint32 {
	a, b := uint32(1), uint32(0)
	for len(data) > 0 {
		n := len(data)
		if n > nmax {
			n = nmax
		}
		for _, x := range data[:n] {
			a += uint32(x)
			b += a
		}
		a %= mod
		b %= mod
		data = data[n:]
	}
	return b<<16 | a
}
