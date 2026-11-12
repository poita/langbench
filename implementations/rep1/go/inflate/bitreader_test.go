package inflate

import "testing"

func TestBitReaderLSBFirst(t *testing.T) {
	br := newBitReader([]byte{0xb5, 0x01}) // 1011 0101, 0000 0001
	want := []struct {
		n uint
		v uint32
	}{{1, 1}, {2, 2}, {3, 6}, {6, 6}}
	for i, w := range want {
		got, err := br.bits(w.n)
		if err != nil || got != w.v {
			t.Fatalf("step %d: bits(%d) = %d, %v; want %d", i, w.n, got, err, w.v)
		}
	}
}

func TestBitReaderTruncated(t *testing.T) {
	br := newBitReader([]byte{0xff})
	if _, err := br.bits(8); err != nil {
		t.Fatal(err)
	}
	if _, err := br.bits(1); err != ErrTruncated {
		t.Fatalf("err = %v, want ErrTruncated", err)
	}
}

func TestBitReaderPeekPastEndIsNotConsumed(t *testing.T) {
	br := newBitReader([]byte{0x01})
	br.refill()
	if br.buf&0xffff != 1 {
		t.Fatalf("peek = %#x", br.buf&0xffff)
	}
	if err := br.consume(9); err != ErrTruncated {
		t.Fatalf("err = %v, want ErrTruncated", err)
	}
}

func TestBitReaderAlignGivesBackBytes(t *testing.T) {
	br := newBitReader([]byte{0x07, 0xaa, 0xbb, 0xcc})
	if _, err := br.bits(3); err != nil {
		t.Fatal(err)
	}
	br.alignToByte()
	if br.pos != 1 || br.remainingBytes() != 3 {
		t.Fatalf("pos=%d remaining=%d", br.pos, br.remainingBytes())
	}
}
