package qr

// bitWriter appends bits MSB-first directly into a byte slice.
type bitWriter struct {
	buf  []byte
	acc  uint32 // pending bits (low nbit bits are valid)
	nbit uint
}

// write appends the low n bits (n <= 24) of v, most significant first.
func (w *bitWriter) write(v uint32, n uint) {
	w.acc = w.acc<<n | (v & (1<<n - 1))
	w.nbit += n
	for w.nbit >= 8 {
		w.nbit -= 8
		w.buf = append(w.buf, byte(w.acc>>w.nbit))
	}
	w.acc &= 1<<w.nbit - 1
}

// bitLen returns the number of bits written so far.
func (w *bitWriter) bitLen() int { return len(w.buf)*8 + int(w.nbit) }

// alignByte pads with zero bits up to a byte boundary.
func (w *bitWriter) alignByte() {
	if w.nbit > 0 {
		w.write(0, 8-w.nbit)
	}
}
