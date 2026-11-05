package charset

import "testing"

func TestLookup(t *testing.T) {
	cases := map[string]Table{
		" US-ASCII\t": ASCII, "UTF8": UTF8, "Latin1": Latin1, "L1": Latin1,
		"windows-1252": CP1252, "": CP1252, "koi8-r": CP1252,
	}
	for name, want := range cases {
		if got := Lookup(name); got != want {
			t.Errorf("Lookup(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestDecodeSingleByte(t *testing.T) {
	if got := Decode([]byte("caf\xe9"), "latin1"); got != "café" {
		t.Errorf("latin1 = %q", got)
	}
	if got := Decode([]byte("smart\x92quote"), "windows-1252"); got != "smart’quote" {
		t.Errorf("cp1252 = %q", got)
	}
	if got := Decode([]byte("\x81\x8d\x80"), "cp1252"); got != "\u0081\u008d€" {
		t.Errorf("cp1252 gaps = %q", got)
	}
	if got := Decode([]byte("a\xe9"), "us-ascii"); got != "a�" {
		t.Errorf("ascii = %q", got)
	}
	if got := Decode([]byte("\xe9"), "unknown"); got != "é" {
		t.Errorf("fallback = %q", got)
	}
}

func TestDecodeUTF8MaximalSubpart(t *testing.T) {
	cases := []struct{ in, want string }{
		{"abc", "abc"},
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
		{"\x80a", "�a"},
		{"\xe2\x82", "�"},
		{"\xe2\x82a", "�a"},
	}
	for _, c := range cases {
		if got := DecodeUTF8([]byte(c.in)); got != c.want {
			t.Errorf("DecodeUTF8(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRuneCount(t *testing.T) {
	if got := RuneCount("café😀"); got != 5 {
		t.Errorf("RuneCount = %d", got)
	}
}
