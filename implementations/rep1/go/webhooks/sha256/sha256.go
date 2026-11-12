// Package sha256 is a from-scratch implementation of SHA-256 (FIPS 180-4).
package sha256

// Size is the digest length in bytes; BlockSize is the block length in bytes.
const (
	Size      = 32
	BlockSize = 64
)

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

var initState = [8]uint32{
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

// Digest is a streaming SHA-256 computation. The zero value is not ready for
// use; call New.
type Digest struct {
	h    [8]uint32
	buf  [BlockSize]byte
	nbuf int
	n    uint64 // total bytes written
}

// New returns a Digest in its initial state.
func New() *Digest {
	d := &Digest{}
	d.Reset()
	return d
}

// Reset returns d to its initial state.
func (d *Digest) Reset() {
	d.h = initState
	d.nbuf = 0
	d.n = 0
}

// Write absorbs p. It never fails.
func (d *Digest) Write(p []byte) (int, error) {
	written := len(p)
	d.n += uint64(written)
	if d.nbuf > 0 {
		c := copy(d.buf[d.nbuf:], p)
		d.nbuf += c
		p = p[c:]
		if d.nbuf < BlockSize {
			return written, nil
		}
		block(&d.h, d.buf[:])
		d.nbuf = 0
	}
	if len(p) >= BlockSize {
		full := len(p) &^ (BlockSize - 1)
		block(&d.h, p[:full])
		p = p[full:]
	}
	if len(p) > 0 {
		d.nbuf = copy(d.buf[:], p)
	}
	return written, nil
}

// Sum finalises a copy of the state and returns the digest; d is unchanged
// and may continue to be written to.
func (d *Digest) Sum() [Size]byte {
	c := *d
	bitLen := c.n << 3
	var pad [BlockSize + 8]byte
	pad[0] = 0x80
	padLen := (55 - int(c.n%BlockSize) + BlockSize) % BlockSize // zeros after 0x80
	padLen += 1
	for i := 0; i < 8; i++ {
		pad[padLen+i] = byte(bitLen >> uint(56-8*i))
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

func ror(x uint32, n uint) uint32 { return x>>n | x<<(32-n) }

// block processes p, whose length must be a multiple of BlockSize.
func block(h *[8]uint32, p []byte) {
	var w [64]uint32
	for len(p) >= BlockSize {
		for t := 0; t < 16; t++ {
			w[t] = uint32(p[4*t])<<24 | uint32(p[4*t+1])<<16 | uint32(p[4*t+2])<<8 | uint32(p[4*t+3])
		}
		for t := 16; t < 64; t++ {
			s0 := ror(w[t-15], 7) ^ ror(w[t-15], 18) ^ w[t-15]>>3
			s1 := ror(w[t-2], 17) ^ ror(w[t-2], 19) ^ w[t-2]>>10
			w[t] = w[t-16] + s0 + w[t-7] + s1
		}
		a, b, c, d, e, f, g, hh := h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
		for t := 0; t < 64; t++ {
			s1 := ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
			ch := e&f ^ ^e&g
			t1 := hh + s1 + ch + k[t] + w[t]
			s0 := ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
			maj := a&b ^ a&c ^ b&c
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
		p = p[BlockSize:]
	}
}
