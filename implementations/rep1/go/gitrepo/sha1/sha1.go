// Package sha1 is a small, dependency-free implementation of SHA-1
// (FIPS 180-4) with a streaming interface.
//
// SHA-1 is cryptographically broken; it is implemented here only because git
// uses it to name objects.
package sha1

import "encoding/binary"

// Size is the size of a SHA-1 digest in bytes.
const Size = 20

// BlockSize is the SHA-1 block size in bytes.
const BlockSize = 64

// Digest is a streaming SHA-1 state. The zero value is not ready for use;
// call New.
type Digest struct {
	h   [5]uint32
	buf [BlockSize]byte
	n   int    // bytes buffered in buf
	len uint64 // total bytes written
	w   [80]uint32
}

// New returns a Digest initialised to the SHA-1 starting state.
func New() *Digest {
	d := new(Digest)
	d.Reset()
	return d
}

// Reset returns d to its initial state.
func (d *Digest) Reset() {
	d.h = [5]uint32{0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}
	d.n = 0
	d.len = 0
}

// Write adds p to the running hash. It never fails.
func (d *Digest) Write(p []byte) (int, error) {
	total := len(p)
	d.len += uint64(total)
	if d.n > 0 {
		c := copy(d.buf[d.n:], p)
		d.n += c
		p = p[c:]
		if d.n < BlockSize {
			return total, nil
		}
		d.block(d.buf[:])
		d.n = 0
	}
	if len(p) >= BlockSize {
		k := len(p) &^ (BlockSize - 1)
		d.block(p[:k])
		p = p[k:]
	}
	if len(p) > 0 {
		d.n = copy(d.buf[:], p)
	}
	return total, nil
}

// Sum finalises a copy of the state and returns the digest; d is unchanged
// and may continue to be written to.
func (d *Digest) Sum() [Size]byte {
	c := *d
	bits := c.len << 3
	var pad [BlockSize + 8]byte
	pad[0] = 0x80
	padLen := (55 - int(c.len%BlockSize) + BlockSize) % BlockSize
	binary.BigEndian.PutUint64(pad[1+padLen:], bits)
	c.Write(pad[:1+padLen+8])
	var out [Size]byte
	for i, v := range c.h {
		binary.BigEndian.PutUint32(out[i*4:], v)
	}
	return out
}

// Sum returns the SHA-1 digest of data.
func Sum(data []byte) [Size]byte {
	d := New()
	d.Write(data)
	return d.Sum()
}

func rotl(x uint32, n uint) uint32 { return x<<n | x>>(32-n) }

// block processes len(p)/64 whole blocks.
func (d *Digest) block(p []byte) {
	w := &d.w
	h0, h1, h2, h3, h4 := d.h[0], d.h[1], d.h[2], d.h[3], d.h[4]
	for ; len(p) >= BlockSize; p = p[BlockSize:] {
		for i := 0; i < 16; i++ {
			w[i] = binary.BigEndian.Uint32(p[i*4:])
		}
		for i := 16; i < 80; i++ {
			w[i] = rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1)
		}
		a, b, c, dd, e := h0, h1, h2, h3, h4
		for i := 0; i < 20; i++ {
			t := rotl(a, 5) + (b&c | ^b&dd) + e + w[i] + 0x5A827999
			e, dd, c, b, a = dd, c, rotl(b, 30), a, t
		}
		for i := 20; i < 40; i++ {
			t := rotl(a, 5) + (b ^ c ^ dd) + e + w[i] + 0x6ED9EBA1
			e, dd, c, b, a = dd, c, rotl(b, 30), a, t
		}
		for i := 40; i < 60; i++ {
			t := rotl(a, 5) + (b&c | b&dd | c&dd) + e + w[i] + 0x8F1BBCDC
			e, dd, c, b, a = dd, c, rotl(b, 30), a, t
		}
		for i := 60; i < 80; i++ {
			t := rotl(a, 5) + (b ^ c ^ dd) + e + w[i] + 0xCA62C1D6
			e, dd, c, b, a = dd, c, rotl(b, 30), a, t
		}
		h0 += a
		h1 += b
		h2 += c
		h3 += dd
		h4 += e
	}
	d.h = [5]uint32{h0, h1, h2, h3, h4}
}
