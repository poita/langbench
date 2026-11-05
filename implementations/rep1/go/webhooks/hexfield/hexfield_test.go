package hexfield_test

import (
	"bytes"
	"testing"

	"example.com/webhooks/hexfield"
)

func TestDecode(t *testing.T) {
	good := map[string][]byte{
		"-":    {},
		"00":   {0},
		"ff":   {0xff},
		"0aff": {0x0a, 0xff},
	}
	for in, want := range good {
		got, err := hexfield.Decode([]byte(in))
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("Decode(%q) = %x, %v; want %x", in, got, err, want)
		}
	}
	for _, in := range []string{"", "a", "abc", "AB", "0G", "--", "-0", "0x", " 0", "ab "} {
		if _, err := hexfield.Decode([]byte(in)); err == nil {
			t.Errorf("Decode(%q) should fail", in)
		}
		if hexfield.Valid([]byte(in)) {
			t.Errorf("Valid(%q) should be false", in)
		}
	}
}

func TestEncode(t *testing.T) {
	if got := hexfield.Encode(nil); got != "-" {
		t.Errorf("empty: %q", got)
	}
	if got := hexfield.Encode([]byte{0x00, 0xab, 0x7f}); got != "00ab7f" {
		t.Errorf("got %q", got)
	}
}
