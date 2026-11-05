package wire

import (
	"bytes"
	"testing"
)

func TestVarintRoundTrip(t *testing.T) {
	cases := []struct {
		v   uint64
		enc string
	}{
		{0, "\x00"}, {1, "\x01"}, {127, "\x7f"}, {128, "\x80\x01"}, {300, "\xac\x02"},
		{1<<64 - 1, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"},
	}
	for _, c := range cases {
		got := AppendVarint(nil, c.v)
		if string(got) != c.enc {
			t.Errorf("AppendVarint(%d) = %x, want %x", c.v, got, c.enc)
		}
		if SizeVarint(c.v) != len(c.enc) {
			t.Errorf("SizeVarint(%d) = %d, want %d", c.v, SizeVarint(c.v), len(c.enc))
		}
		v, n, err := ConsumeVarint([]byte(c.enc+"zz"), MaxVarintLen)
		if err != nil || v != c.v || n != len(c.enc) {
			t.Errorf("ConsumeVarint(%x) = %d,%d,%v", c.enc, v, n, err)
		}
	}
}

func TestConsumeVarintEdgeCases(t *testing.T) {
	// Non-minimal and wrapped encodings are accepted.
	if v, n, err := ConsumeVarint([]byte{0x81, 0x00}, 10); err != nil || v != 1 || n != 2 {
		t.Errorf("non-minimal: %d %d %v", v, n, err)
	}
	if v, _, err := ConsumeVarint(bytes.Repeat([]byte{0xff}, 9), 10); err == nil {
		t.Errorf("9 continuation bytes should be truncated, got %d", v)
	}
	max := append(bytes.Repeat([]byte{0xff}, 9), 0x7f)
	if v, _, err := ConsumeVarint(max, 10); err != nil || v != 1<<64-1 {
		t.Errorf("max: %d %v", v, err)
	}
	wrap := append(bytes.Repeat([]byte{0x80}, 9), 0x02)
	if v, _, err := ConsumeVarint(wrap, 10); err != nil || v != 0 {
		t.Errorf("wrap: %d %v", v, err)
	}
	if _, _, err := ConsumeVarint(bytes.Repeat([]byte{0x80}, 11), 10); err != ErrTooLong {
		t.Errorf("11 bytes: %v", err)
	}
	if _, _, err := ConsumeVarint([]byte{0x80, 0x80, 0x80, 0x80, 0x80, 0x01}, MaxTagLen); err != ErrTooLong {
		t.Errorf("6-byte tag: %v", err)
	}
	if _, _, err := ConsumeVarint([]byte{0x80}, 10); err != ErrTruncated {
		t.Errorf("truncated: %v", err)
	}
	if _, _, err := ConsumeVarint(nil, 10); err != ErrTruncated {
		t.Errorf("empty: %v", err)
	}
}

func TestZigZag(t *testing.T) {
	pairs32 := map[int32]uint32{0: 0, -1: 1, 1: 2, -2: 3, 2: 4, -1 << 31: 1<<32 - 1, 1<<31 - 1: 1<<32 - 2}
	for v, u := range pairs32 {
		if ZigZag32(v) != u || UnZigZag32(u) != v {
			t.Errorf("zigzag32 %d <-> %d", v, u)
		}
	}
	pairs64 := map[int64]uint64{0: 0, -1: 1, 1: 2, -1 << 63: 1<<64 - 1, -128: 255}
	for v, u := range pairs64 {
		if ZigZag64(v) != u || UnZigZag64(u) != v {
			t.Errorf("zigzag64 %d <-> %d", v, u)
		}
	}
}

func TestFixed(t *testing.T) {
	b := AppendFixed32(nil, 0x01020304)
	if !bytes.Equal(b, []byte{4, 3, 2, 1}) || ReadFixed32(b) != 0x01020304 {
		t.Errorf("fixed32 %x", b)
	}
	b = AppendFixed64(nil, 0x0102030405060708)
	if !bytes.Equal(b, []byte{8, 7, 6, 5, 4, 3, 2, 1}) || ReadFixed64(b) != 0x0102030405060708 {
		t.Errorf("fixed64 %x", b)
	}
}

func TestAppendTag(t *testing.T) {
	if got := AppendTag(nil, 1, Varint); !bytes.Equal(got, []byte{0x08}) {
		t.Errorf("tag %x", got)
	}
	if got := AppendTag(nil, 536870911, Bytes); len(got) != 5 {
		t.Errorf("max tag %x", got)
	}
}

func TestHex(t *testing.T) {
	if got := string(AppendHex([]byte("p:"), []byte{0x00, 0xab, 0xff})); got != "p:00abff" {
		t.Errorf("AppendHex = %q", got)
	}
	got, ok := AppendUnhex(nil, []byte("00abff"))
	if !ok || !bytes.Equal(got, []byte{0, 0xab, 0xff}) {
		t.Errorf("AppendUnhex = %x %v", got, ok)
	}
	for _, bad := range []string{"0", "abc", "AB", "0g", "g0", " 0", "0 "} {
		prefix := []byte{9}
		got, ok := AppendUnhex(prefix, []byte(bad))
		if ok || !bytes.Equal(got, prefix) {
			t.Errorf("AppendUnhex(%q) = %x, %v", bad, got, ok)
		}
	}
	if _, ok := HexValue('F'); ok {
		t.Error("uppercase accepted")
	}
	if v, ok := HexValue('f'); !ok || v != 15 {
		t.Error("HexValue f")
	}
}
