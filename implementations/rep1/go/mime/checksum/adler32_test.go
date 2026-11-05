package checksum

import (
	"bytes"
	"testing"
)

func TestAdler32(t *testing.T) {
	if got := Adler32(nil); got != 1 {
		t.Errorf("empty = %08x", got)
	}
	if got := Adler32([]byte("Wikipedia")); got != 0x11E60398 {
		t.Errorf("Wikipedia = %08x", got)
	}
	if got := Adler32([]byte{0, 1, 2, 3}); got != 0x000e0007 {
		t.Errorf("0..3 = %08x", got)
	}
}

// naive is the definition: reduce after every byte.
func naive(data []byte) uint32 {
	a, b := uint32(1), uint32(0)
	for _, x := range data {
		a = (a + uint32(x)) % 65521
		b = (b + a) % 65521
	}
	return b<<16 | a
}

func TestDeferredModuloMatchesDefinition(t *testing.T) {
	data := bytes.Repeat([]byte{0xFF, 0x80, 0x01}, 20000)
	for _, n := range []int{5551, 5552, 5553, 11104, 60000} {
		if got, want := Adler32(data[:n]), naive(data[:n]); got != want {
			t.Errorf("n=%d: %08x, want %08x", n, got, want)
		}
	}
}
