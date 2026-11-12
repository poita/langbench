package inflate

import "testing"

func TestBuildShapes(t *testing.T) {
	tests := []struct {
		name    string
		lengths []uint8
		kind    codeKind
		single  bool
	}{
		{"empty", []uint8{0, 0, 0}, codeEmpty, false},
		{"complete", []uint8{1, 2, 2}, codeComplete, false},
		{"incomplete", []uint8{2, 2, 2}, codeIncomplete, false},
		{"single1", []uint8{0, 1}, codeIncomplete, true},
		{"single2", []uint8{0, 2}, codeIncomplete, false},
		{"over", []uint8{1, 1, 1}, codeOversubscribed, false},
	}
	for _, tc := range tests {
		var h huffTable
		s := h.build(tc.lengths, 4)
		if s.kind != tc.kind || s.singleBit() != tc.single {
			t.Errorf("%s: got %+v, want kind %d single %v", tc.name, s, tc.kind, tc.single)
		}
	}
}

// TestDecodeCanonical checks codes against the example in RFC 1951 3.2.2:
// lengths (3,3,3,3,3,2,4,4) give A=010 B=011 C=100 D=101 E=110 F=00 G=1110 H=1111.
func TestDecodeCanonical(t *testing.T) {
	lengths := []uint8{3, 3, 3, 3, 3, 2, 4, 4}
	codes := []string{"010", "011", "100", "101", "110", "00", "1110", "1111"}
	for _, root := range []uint{2, 3, 7} { // exercise subtables too
		var h huffTable
		if s := h.build(lengths, root); s.kind != codeComplete {
			t.Fatalf("kind = %d", s.kind)
		}
		for sym, c := range codes {
			// Pack the code MSB-first into a byte stream.
			var b byte
			for i, ch := range c {
				if ch == '1' {
					b |= 1 << uint(i)
				}
			}
			br := newBitReader([]byte{b})
			br.refill()
			got, err := h.decode(&br)
			if err != nil || got != sym {
				t.Errorf("root %d code %s: got %d, %v; want %d", root, c, got, err, sym)
			}
			if br.n != 8-uint(len(c)) {
				t.Errorf("root %d code %s consumed wrong bit count", root, c)
			}
		}
	}
}

func TestDecodeLongCodes(t *testing.T) {
	// 1,2,...,15 bits plus one extra 15-bit code: a complete code.
	lengths := make([]uint8, 16)
	for i := range 15 {
		lengths[i] = uint8(i + 1)
	}
	lengths[15] = 15
	var h huffTable
	if s := h.build(lengths, 6); s.kind != codeComplete {
		t.Fatalf("kind = %d", s.kind)
	}
	// Symbol 14 has the code 1^14 0 and symbol 15 has 1^15.
	data := []byte{0xff, 0x7f} // fifteen 1 bits
	br := newBitReader(data)
	br.refill()
	got, err := h.decode(&br)
	if err != nil || got != 15 {
		t.Fatalf("got %d, %v; want 15", got, err)
	}
}

func TestIncompleteInvalidPattern(t *testing.T) {
	var h huffTable
	h.build([]uint8{0, 1}, 4)
	br := newBitReader([]byte{0x01}) // first bit 1: not a code
	br.refill()
	if _, err := h.decode(&br); err != ErrInvalidCode {
		t.Fatalf("err = %v", err)
	}
	br = newBitReader([]byte{0x00})
	br.refill()
	if s, err := h.decode(&br); err != nil || s != 1 {
		t.Fatalf("got %d, %v", s, err)
	}
}
