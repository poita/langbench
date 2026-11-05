// Package sha256 is a from-scratch implementation of SHA-256 (FIPS 180-4).
//
// The Hasher is an incremental hasher whose zero value is NOT ready for use;
// call New (or Reset). A Hasher holds no pointers, so it can be copied by
// assignment to snapshot its state, which is how package hmac reuses the
// precomputed ipad/opad states.
package sha256

import "math/bits"

// Size is the length of a SHA-256 digest in bytes.
const Size = 32

// BlockSize is the SHA-256 block size in bytes.
const BlockSize = 64

var initState = [8]uint32{
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

var k = [64]uint32{
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

// Hasher computes a SHA-256 digest incrementally.
type Hasher struct {
	h   [8]uint32
	buf [BlockSize]byte
	n   int    // bytes currently buffered in buf
	len uint64 // total bytes written
}

// New returns a Hasher ready to receive data.
func New() Hasher {
	return Hasher{h: initState}
}

// Reset returns the hasher to its initial state.
func (d *Hasher) Reset() {
	*d = Hasher{h: initState}
}

// Write absorbs p. It never fails. Full blocks are compressed directly from p
// without being copied.
func (d *Hasher) Write(p []byte) (int, error) {
	total := len(p)
	d.len += uint64(total)
	if d.n > 0 {
		c := copy(d.buf[d.n:], p)
		d.n += c
		p = p[c:]
		if d.n < BlockSize {
			return total, nil
		}
		compress(&d.h, d.buf[:])
		d.n = 0
	}
	if len(p) >= BlockSize {
		full := len(p) &^ (BlockSize - 1)
		compress(&d.h, p[:full])
		p = p[full:]
	}
	if len(p) > 0 {
		d.n = copy(d.buf[:], p)
	}
	return total, nil
}

// WriteString absorbs s without allocating.
func (d *Hasher) WriteString(s string) {
	d.len += uint64(len(s))
	for len(s) > 0 {
		c := copy(d.buf[d.n:], s)
		d.n += c
		s = s[c:]
		if d.n == BlockSize {
			compress(&d.h, d.buf[:])
			d.n = 0
		}
	}
}

// Sum returns the digest of everything written so far. It does not change the
// state of d, so more data may be written afterwards.
func (d *Hasher) Sum() [Size]byte {
	c := *d
	bitLen := d.len << 3
	var pad [BlockSize + 8]byte
	pad[0] = 0x80
	// padLen counts the 0x80 byte and the zeros up to 56 mod 64.
	var padLen int
	if c.n < 56 {
		padLen = 56 - c.n
	} else {
		padLen = 120 - c.n
	}
	for i := 0; i < 8; i++ {
		pad[padLen+i] = byte(bitLen >> (56 - 8*uint(i)))
	}
	c.Write(pad[:padLen+8])
	var out [Size]byte
	for i, v := range c.h {
		out[4*i] = byte(v >> 24)
		out[4*i+1] = byte(v >> 16)
		out[4*i+2] = byte(v >> 8)
		out[4*i+3] = byte(v)
	}
	return out
}

// Sum256 returns the SHA-256 digest of data.
func Sum256(data []byte) [Size]byte {
	d := New()
	d.Write(data)
	return d.Sum()
}

// compress runs the compression function over p, whose length must be a
// multiple of BlockSize. The message schedule and working variables live in
// fixed-size local storage.
func compress(h *[8]uint32, p []byte) {
	var w [64]uint32
	for ; len(p) >= BlockSize; p = p[BlockSize:] {
		for t := 0; t < 16; t++ {
			w[t] = uint32(p[4*t])<<24 | uint32(p[4*t+1])<<16 | uint32(p[4*t+2])<<8 | uint32(p[4*t+3])
		}
		for t := 16; t < 64; t++ {
			x, y := w[t-15], w[t-2]
			s0 := bits.RotateLeft32(x, -7) ^ bits.RotateLeft32(x, -18) ^ (x >> 3)
			s1 := bits.RotateLeft32(y, -17) ^ bits.RotateLeft32(y, -19) ^ (y >> 10)
			w[t] = w[t-16] + s0 + w[t-7] + s1
		}
		a, b, c, d, e, f, g, hh := h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
		for t := 0; t < 64; t++ {
			s1 := bits.RotateLeft32(e, -6) ^ bits.RotateLeft32(e, -11) ^ bits.RotateLeft32(e, -25)
			ch := (e & f) ^ (^e & g)
			t1 := hh + s1 + ch + k[t] + w[t]
			s0 := bits.RotateLeft32(a, -2) ^ bits.RotateLeft32(a, -13) ^ bits.RotateLeft32(a, -22)
			maj := (a & b) ^ (a & c) ^ (b & c)
			t2 := s0 + maj
			hh, g, f, e, d, c, b, a = g, f, e, d+t1, c, b, a, t1+t2
		}
		h[0] += a
		h[1] += b
		h[2] += c
		h[3] += d
		h[4] += e
		h[5] += f
		h[6] += g
		h[7] += hh
	}
}
