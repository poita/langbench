package crc

import "testing"

func TestVectors(t *testing.T) {
	tests := []struct {
		in   string
		want uint32
	}{
		{"", 0},
		{"a", 0xE8B7BE43},
		{"123456789", 0xCBF43926},
		{"TESSERA1", 0x2C9A9B66},
		{"TESSWAL1", 0x7D446716},
		{string(make([]byte, 20)), 0x0FD59B8D},
		{string(make([]byte, 1024)), 0xEFB5AF2E},
	}
	for _, tc := range tests {
		if got := Checksum([]byte(tc.in)); got != tc.want {
			t.Errorf("Checksum(%.10q) = %#x, want %#x", tc.in, got, tc.want)
		}
	}
}

func TestUpdateChains(t *testing.T) {
	whole := Checksum([]byte("123456789"))
	chained := Update(Checksum([]byte("1234")), []byte("56789"))
	if whole != chained {
		t.Fatalf("chained %#x != whole %#x", chained, whole)
	}
}
