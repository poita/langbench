package jsoncanon

import (
	"testing"
	"unicode/utf8"
)

func TestValidUTF8(t *testing.T) {
	tests := []struct {
		in string
		ok bool
	}{
		{"", true},
		{"hello world, this is plain ascii text", true},
		{"é€😀\U0010FFFF\u007f", true},
		{"\xC0\x80", false},
		{"\xC1\xBF", false},
		{"\xE0\x9F\xBF", false},
		{"\xF0\x8F\xBF\xBF", false},
		{"\xED\xA0\x80", false},
		{"\xED\xBF\xBF", false},
		{"\xF4\x90\x80\x80", false},
		{"\xF8\x88\x80\x80\x80", false},
		{"\xFF", false},
		{"\x80", false},
		{"\xC3", false},
		{"\xE2\x82", false},
		{"\xF0\x9F\x98", false},
		{"abcdefghijklmnop\xff", false},
		{"abcdefghijklmnop\xC3", false},
	}
	for _, tc := range tests {
		if ok, _ := validUTF8([]byte(tc.in)); ok != tc.ok {
			t.Errorf("validUTF8(%q) = %v, want %v", tc.in, ok, tc.ok)
		}
	}
}

// TestValidUTF8Exhaustive compares against the standard library for every
// 1–3 byte combination drawn from interesting bytes.
func TestValidUTF8Exhaustive(t *testing.T) {
	bytes := []byte{0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF,
		0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF}
	var rec func(buf []byte)
	rec = func(buf []byte) {
		if ok, _ := validUTF8(buf); ok != utf8.Valid(buf) {
			t.Fatalf("mismatch on % x: got %v", buf, ok)
		}
		if len(buf) == 4 {
			return
		}
		for _, b := range bytes {
			rec(append(buf[:len(buf):len(buf)], b))
		}
	}
	rec(nil)
}
