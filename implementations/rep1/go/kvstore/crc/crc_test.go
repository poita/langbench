package crc

import (
	"bytes"
	"testing"
)

func TestVectors(t *testing.T) {
	tests := []struct {
		name string
		in   []byte
		want uint32
	}{
		{"empty", nil, 0x00000000},
		{"a", []byte("a"), 0xE8B7BE43},
		{"digits", []byte("123456789"), 0xCBF43926},
		{"TESSERA1", []byte("TESSERA1"), 0x2C9A9B66},
		{"TESSWAL1", []byte("TESSWAL1"), 0x7D446716},
		{"20 zeros", make([]byte, 20), 0x0FD59B8D},
		{"1024 zeros", make([]byte, 1024), 0xEFB5AF2E},
	}
	for _, tc := range tests {
		if got := Checksum(tc.in); got != tc.want {
			t.Errorf("%s: got %#08x, want %#08x", tc.name, got, tc.want)
		}
	}
}

func TestUpdateIsIncremental(t *testing.T) {
	data := bytes.Repeat([]byte("tessera"), 100)
	whole := Checksum(data)
	for _, split := range []int{0, 1, 7, 350, len(data)} {
		got := Update(Checksum(data[:split]), data[split:])
		if got != whole {
			t.Errorf("split %d: got %#08x, want %#08x", split, got, whole)
		}
	}
}

func bitwise(data []byte) uint32 {
	crc := uint32(0xFFFFFFFF)
	for _, b := range data {
		crc ^= uint32(b)
		for i := 0; i < 8; i++ {
			if crc&1 != 0 {
				crc = (crc >> 1) ^ 0xEDB88320
			} else {
				crc >>= 1
			}
		}
	}
	return crc ^ 0xFFFFFFFF
}

func TestMatchesBitwiseDefinition(t *testing.T) {
	for n := 0; n < 300; n++ {
		data := make([]byte, n)
		for i := range data {
			data[i] = byte(i*31 + n)
		}
		if Checksum(data) != bitwise(data) {
			t.Fatalf("mismatch at length %d", n)
		}
	}
}
