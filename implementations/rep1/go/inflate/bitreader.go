package inflate

import "encoding/binary"

// bitReader serves bits LSB-first from a byte slice through a 64-bit buffer.
//
// buf holds n valid bits in its low end; bits above n may hold look-ahead
// copies of the following stream bits (or zeros), which is harmless because a
// later refill ORs the very same values into the same positions. Beyond the
// end of data the reader supplies zero bytes so that code lookups can peek
// past the end; pos then exceeds len(data), and overrun reports whether any
// of those phantom bits has actually been consumed.
type bitReader struct {
	data []byte
	pos  int    // bytes loaded into buf, including phantom bytes past the end
	buf  uint64 // bit buffer, next bit in bit 0
	n    uint   // number of valid bits in buf
}

func (b *bitReader) reset(data []byte) {
	*b = bitReader{data: data}
}

// refill tops the buffer up so that at least 56 bits are available.
func (b *bitReader) refill() {
	if b.pos+8 <= len(b.data) {
		b.buf |= binary.LittleEndian.Uint64(b.data[b.pos:]) << b.n
		b.pos += int(63-b.n) >> 3
		b.n |= 56
		return
	}
	b.refillSlow()
}

// refillSlow is the byte-at-a-time refill used near the end of the data; it
// appends zero bits once the real data runs out.
func (b *bitReader) refillSlow() {
	for b.n <= 56 {
		var c byte
		if b.pos < len(b.data) {
			c = b.data[b.pos]
		}
		b.buf |= uint64(c) << b.n
		b.pos++
		b.n += 8
	}
}

// take consumes and returns k bits (k <= 32); the caller must have refilled.
func (b *bitReader) take(k uint) uint32 {
	v := uint32(b.buf & (1<<k - 1))
	b.buf >>= k
	b.n -= k
	return v
}

// consumed returns the number of bits consumed so far (phantom bits included).
func (b *bitReader) consumed() int {
	return b.pos*8 - int(b.n)
}

// overrun reports whether bits beyond the end of the data were consumed.
func (b *bitReader) overrun() bool {
	return b.pos > len(b.data) && b.consumed() > len(b.data)*8
}

// alignToByte discards bits up to the next byte boundary.
func (b *bitReader) alignToByte() {
	b.take(b.n & 7)
}

// seekByte discards the buffer and restarts reading at byte offset p.
func (b *bitReader) seekByte(p int) {
	b.pos, b.buf, b.n = p, 0, 0
}

func le64(b []byte) uint64 { return binary.LittleEndian.Uint64(b) }
