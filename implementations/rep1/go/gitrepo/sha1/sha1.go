// Package sha1 is a small, self-contained implementation of the SHA-1 hash
// function (FIPS 180-4).
//
// It exists because git object ids are SHA-1 digests and this project reads
// repositories without relying on any hashing library. SHA-1 is broken as a
// collision-resistant hash; it is used here only because git uses it.
package sha1

import "encoding/binary"

// Size is the size of a SHA-1 checksum in bytes.
const Size = 20

// BlockSize is the block size of SHA-1 in bytes.
const BlockSize = 64

// Digest is a streaming SHA-1 computation. The zero value is not ready for
// use; create one with New.
type Digest struct {
	h   [5]uint32
	buf [BlockSize]byte
	n   int    // bytes currently buffered in buf
	len uint64 // total bytes written
}

// New returns a new Digest.
func New() *Digest {
	d := &Digest{}
	d.Reset()
	return d
}

// Reset restores d to its initial state.
func (d *Digest) Reset() {
	d.h = [5]uint32{0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}
	d.n = 0
	d.len = 0
}

// Write adds p to the running hash. It never returns an error.
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
		full := len(p) &^ (BlockSize - 1)
		d.block(p[:full])
		p = p[full:]
	}
	if len(p) > 0 {
		d.n = copy(d.buf[:], p)
	}
	return total, nil
}

// WriteString is like Write for a string.
func (d *Digest) WriteString(s string) { d.Write([]byte(s)) }

// Sum appends the current hash to b and returns the result. It does not
// change the state of d.
func (d *Digest) Sum(b []byte) []byte {
	c := *d // work on a copy so that d can keep being written to
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
	return append(b, out[:]...)
}

// Sum returns the SHA-1 checksum of data.
func Sum(data []byte) [Size]byte {
	d := New()
	d.Write(data)
	var out [Size]byte
	copy(out[:], d.Sum(nil))
	return out
}

func rotl(x uint32, n uint) uint32 { return x<<n | x>>(32-n) }

func (d *Digest) block(p []byte) {
	var w [80]uint32
	h0, h1, h2, h3, h4 := d.h[0], d.h[1], d.h[2], d.h[3], d.h[4]
	for ; len(p) >= BlockSize; p = p[BlockSize:] {
		for i := 0; i < 16; i++ {
			w[i] = binary.BigEndian.Uint32(p[i*4:])
		}
		for i := 16; i < 80; i++ {
			w[i] = rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1)
		}
		a, b, c, dd, e := h0, h1, h2, h3, h4
		for i := 0; i < 80; i++ {
			var f, k uint32
			switch {
			case i < 20:
				f, k = b&c|^b&dd, 0x5A827999
			case i < 40:
				f, k = b^c^dd, 0x6ED9EBA1
			case i < 60:
				f, k = b&c|b&dd|c&dd, 0x8F1BBCDC
			default:
				f, k = b^c^dd, 0xCA62C1D6
			}
			t := rotl(a, 5) + f + e + k + w[i]
			a, b, c, dd, e = t, a, rotl(b, 30), c, dd
		}
		h0 += a
		h1 += b
		h2 += c
		h3 += dd
		h4 += e
	}
	d.h = [5]uint32{h0, h1, h2, h3, h4}
}
