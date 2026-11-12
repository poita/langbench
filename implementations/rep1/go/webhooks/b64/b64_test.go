package b64

import (
	"bytes"
	"testing"
)

func TestEncode(t *testing.T) {
	tests := []struct {
		in       []byte
		std, url string
	}{
		{nil, "", ""},
		{[]byte("f"), "Zg==", "Zg"},
		{[]byte("fo"), "Zm8=", "Zm8"},
		{[]byte("foo"), "Zm9v", "Zm9v"},
		{[]byte("foob"), "Zm9vYg==", "Zm9vYg"},
		{[]byte{0xfb, 0xff}, "+/8=", "-_8"},
	}
	for _, tc := range tests {
		if got := EncodeStd(tc.in); got != tc.std {
			t.Errorf("EncodeStd(%q) = %q, want %q", tc.in, got, tc.std)
		}
		if got := EncodeURL(tc.in); got != tc.url {
			t.Errorf("EncodeURL(%q) = %q, want %q", tc.in, got, tc.url)
		}
	}
}

func TestDecodeValid(t *testing.T) {
	tests := []struct {
		in   string
		want []byte
	}{
		{"", []byte{}},
		{"Zg==", []byte("f")},
		{"Zg", []byte("f")},
		{"Zm8=", []byte("fo")},
		{"Zm8", []byte("fo")},
		{"+/8=", []byte{0xfb, 0xff}},
		{"-_8", []byte{0xfb, 0xff}},
		{"QQ==", []byte("A")},
		{"QR==", []byte("A")}, // trailing bits are ignored
	}
	for _, tc := range tests {
		got, err := Decode(tc.in)
		if err != nil || !bytes.Equal(got, tc.want) {
			t.Errorf("Decode(%q) = %v, %v; want %v", tc.in, got, err, tc.want)
		}
	}
}

func TestDecodeInvalid(t *testing.T) {
	for _, in := range []string{
		"=", "====", "Z", "Zg=", "Zg===", "Zm8==", "Zm9v=", "Zm=8", "=Zg",
		"+-", "/_", "Zm9v ", " Zm9v", "Zm9v\n", "Zm!v", "Zm9", "Zm9v=Zm9v", "é",
	} {
		// "Zm9" is valid unpadded (n mod 4 == 3); keep it out of this list.
		if in == "Zm9" {
			continue
		}
		if got, err := Decode(in); err == nil {
			t.Errorf("Decode(%q) = %v, want error", in, got)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	for n := 0; n < 40; n++ {
		src := make([]byte, n)
		for i := range src {
			src[i] = byte(i*37 + n)
		}
		for _, enc := range []string{EncodeStd(src), EncodeURL(src)} {
			got, err := Decode(enc)
			if err != nil || !bytes.Equal(got, src) {
				t.Errorf("round trip of %d bytes via %q failed: %v", n, enc, err)
			}
		}
	}
}
