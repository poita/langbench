package b64_test

import (
	"bytes"
	"testing"

	"example.com/webhooks/b64"
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
		if got := b64.Encode(tc.in); got != tc.std {
			t.Errorf("Encode(%x) = %q want %q", tc.in, got, tc.std)
		}
		if got := b64.EncodeURL(tc.in); got != tc.url {
			t.Errorf("EncodeURL(%x) = %q want %q", tc.in, got, tc.url)
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
		{"Zm9v", []byte("foo")},
		{"+/8=", []byte{0xfb, 0xff}},
		{"-_8", []byte{0xfb, 0xff}},
		{"QQ==", []byte("A")}, // trailing bits are not checked
		{"QR==", []byte("A")},
	}
	for _, tc := range tests {
		got, err := b64.Decode(tc.in)
		if err != nil || !bytes.Equal(got, tc.want) {
			t.Errorf("Decode(%q) = %x, %v; want %x", tc.in, got, err, tc.want)
		}
	}
}

func TestDecodeInvalid(t *testing.T) {
	for _, in := range []string{
		"A",     // n mod 4 == 1
		"AAAAA", // n mod 4 == 1
		"Zg=",   // wrong padding amount
		"Zm8==", // wrong padding amount
		"Zm9v=", // padding on a full group
		"Zg===", // three pads
		"Z=g=",  // = in the middle
		"=Zg=",  // = at the start
		"+/-_",  // mixed alphabets
		"Zm 8",  // whitespace
		"Zm8\n", // newline
		"Zm8*",  // foreign character
		"=",     // only padding
		"====",
		"Zm9\xff", // non-ASCII
	} {
		if got, err := b64.Decode(in); err == nil {
			t.Errorf("Decode(%q) = %x, want error", in, got)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	var data []byte
	for i := 0; i < 50; i++ {
		data = append(data, byte(i*37+11))
		for _, enc := range []string{b64.Encode(data), b64.EncodeURL(data)} {
			got, err := b64.Decode(enc)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("len %d: %q -> %x, %v", len(data), enc, got, err)
			}
		}
	}
}

func TestAppendDecodeLeavesDstOnError(t *testing.T) {
	dst := []byte("keep")
	out, err := b64.AppendDecode(dst, "A")
	if err == nil || string(out) != "keep" {
		t.Fatalf("got %q, %v", out, err)
	}
}
