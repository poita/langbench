package charset

import "testing"

func TestDecodeUTF8MaximalSubpart(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"plain", "plain"},
		{"caf\xc3\xa9", "café"},
		{"\xe2\x28\xa1", "�(�"},
		{"\xf0\x9f", "�"},
		{"\xf0\x9f\x98", "�"},
		{"\xf0\x9f\x98\x80", "😀"},
		{"\xed\xa0\x80", "���"}, // surrogate: ED then A0 is out of range
		{"\xc0\xaf", "��"},
		{"\xe0\x80\x80", "���"},
		{"\xf4\x90\x80\x80", "����"},
		{"\xff", "�"},
		{"a\x80b", "a�b"},
		{"\xe2\x82", "�"},
		{"\xe2\x82(", "�("},
	}
	for _, tc := range tests {
		if got := DecodeUTF8([]byte(tc.in)); got != tc.want {
			t.Errorf("DecodeUTF8(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestDecodeNamedCharsets(t *testing.T) {
	tests := []struct {
		in      string
		charset string
		want    string
	}{
		{"caf\xe9", "iso-8859-1", "café"},
		{"caf\xe9", " LATIN1\t", "café"},
		{"caf\xe9", "us-ascii", "caf�"},
		{"smart\x92quote", "windows-1252", "smart’quote"},
		{"smart\x92quote", "", "smart’quote"},
		{"smart\x92quote", "x-unknown", "smart’quote"},
		{"smart\x92quote", "iso-8859-1", "smart\u0092quote"},
		{"\x81\x8d\x8f\x90\x9d", "cp1252", "\u0081\u008d\u008f\u0090\u009d"},
		{"\xc3\xa9", "UTF8", "é"},
		{"\x80\xff", "cp1252", "€ÿ"},
	}
	for _, tc := range tests {
		if got := Decode([]byte(tc.in), tc.charset); got != tc.want {
			t.Errorf("Decode(%q, %q) = %q, want %q", tc.in, tc.charset, got, tc.want)
		}
	}
}

func TestNormalize(t *testing.T) {
	if got := Normalize(" \tUTF-8 \t"); got != "utf-8" {
		t.Errorf("got %q", got)
	}
}
