package inflate

// bitReader reads an LSB-first bit stream from a byte slice.
//
// Bits are held in a 64-bit buffer. peeking past the end of the data yields
// zero bits, but consume reports ErrTruncated if it would use bits that do not
// exist.
type bitReader struct {
	data []byte
	pos  int    // next byte of data to load into buf
	buf  uint64 // pending bits, next bit in the least significant position
	n    uint   // number of valid bits in buf
}

func newBitReader(data []byte) bitReader { return bitReader{data: data} }

// refill tops the buffer up to at least 56 bits, or all remaining input.
func (b *bitReader) refill() {
	for b.n <= 56 && b.pos < len(b.data) {
		b.buf |= uint64(b.data[b.pos]) << b.n
		b.pos++
		b.n += 8
	}
}

// consume discards n bits that are known to have been peeked.
func (b *bitReader) consume(n uint) error {
	if n > b.n {
		return ErrTruncated
	}
	b.buf >>= n
	b.n -= n
	return nil
}

// bits reads an n-bit (n <= 32) little-endian numeric field.
func (b *bitReader) bits(n uint) (uint32, error) {
	b.refill()
	v := uint32(b.buf & (1<<n - 1))
	if err := b.consume(n); err != nil {
		return 0, err
	}
	return v, nil
}

// alignToByte discards the bits left in the current byte and hands every
// prefetched whole byte back to the underlying data, so that the next read
// position is data[b.pos].
func (b *bitReader) alignToByte() {
	b.pos -= int(b.n / 8)
	b.buf, b.n = 0, 0
}

// remainingBytes reports how many whole bytes are left unread, ignoring a
// partially consumed byte.
func (b *bitReader) remainingBytes() int {
	return len(b.data) - b.pos + int(b.n/8)
}
