package inflate

import "testing"

func TestBitReaderTake(t *testing.T) {
	// 0xb5 = 10110101, 0x1c = 00011100; bits are read LSB first.
	br := &bitReader{}
	br.reset([]byte{0xb5, 0x1c})
	br.refill()
	if got := br.take(3); got != 0b101 {
		t.Errorf("take(3) = %b, want 101", got)
	}
	if got := br.take(7); got != 0b10110 {
		t.Errorf("take(7) = %b, want 10110", got)
	}
	if got := br.consumed(); got != 10 {
		t.Errorf("consumed = %d, want 10", got)
	}
	if br.overrun() {
		t.Error("overrun before end of data")
	}
}

func TestBitReaderOverrun(t *testing.T) {
	for _, tc := range []struct {
		data    []byte
		take    uint
		overrun bool
	}{
		{nil, 0, false},
		{nil, 1, true},
		{[]byte{0xff}, 8, false},
		{[]byte{0xff}, 9, true},
		{make([]byte, 20), 16, false}, // fast refill path
	} {
		br := &bitReader{}
		br.reset(tc.data)
		br.refill()
		br.take(tc.take)
		if got := br.overrun(); got != tc.overrun {
			t.Errorf("len %d take %d: overrun = %v, want %v", len(tc.data), tc.take, got, tc.overrun)
		}
	}
}

func TestBitReaderPhantomBitsAreZero(t *testing.T) {
	br := &bitReader{}
	br.reset([]byte{0xff})
	br.refill()
	if got := br.take(16); got != 0x00ff {
		t.Errorf("take(16) = %#x, want 0xff", got)
	}
}

func TestBitReaderLongRead(t *testing.T) {
	// Reading 13 bits at a time must agree with reading one bit at a time,
	// across the fast and slow refill paths.
	data := make([]byte, 100)
	for i := range data {
		data[i] = byte(i*37 + 11)
	}
	a, b := &bitReader{}, &bitReader{}
	a.reset(data)
	b.reset(data)
	for i := 0; i < len(data)*8/13; i++ {
		a.refill()
		want := uint32(0)
		for j := uint(0); j < 13; j++ {
			b.refill()
			want |= b.take(1) << j
		}
		if got := a.take(13); got != want {
			t.Fatalf("read %d: got %#x, want %#x", i, got, want)
		}
	}
}

func TestAlignAndSeek(t *testing.T) {
	br := &bitReader{}
	br.reset([]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12})
	br.refill()
	br.take(3)
	br.alignToByte()
	if got := br.consumed(); got != 8 {
		t.Errorf("consumed after align = %d, want 8", got)
	}
	br.seekByte(5)
	br.refill()
	if got := br.take(8); got != 6 {
		t.Errorf("after seek got %d, want 6", got)
	}
}
