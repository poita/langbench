package sha1

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestKnownVectors(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "da39a3ee5e6b4b0d3255bfef95601890afd80709"},
		{"abc", "a9993e364706816aba3e25717850c26c9cd0d89d"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"},
		{"blob 9\x00one file\n", "b7814cae2e925fe74c6cd5816462fff515ccb256"},
		{strings.Repeat("a", 1000000), "34aa973cd4c4daa4f61eeb2bdbad27316534016f"},
	}
	for _, c := range cases {
		s := Sum([]byte(c.in))
		if got := hex.EncodeToString(s[:]); got != c.want {
			t.Errorf("Sum(%.20q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestStreamingChunks(t *testing.T) {
	data := []byte(strings.Repeat("The quick brown fox jumps over the lazy dog. ", 50))
	want := Sum(data)
	for _, chunk := range []int{1, 3, 63, 64, 65, 200} {
		d := New()
		for i := 0; i < len(data); i += chunk {
			j := i + chunk
			if j > len(data) {
				j = len(data)
			}
			d.Write(data[i:j])
		}
		if got := d.Sum(); got != want {
			t.Errorf("chunk %d: digest mismatch", chunk)
		}
	}
}

func TestPaddingBoundaries(t *testing.T) {
	// Lengths around the 55/56/63/64 byte padding edge cases must agree
	// between one-shot and byte-wise hashing.
	for n := 50; n < 70; n++ {
		data := []byte(strings.Repeat("x", n))
		d := New()
		for _, b := range data {
			d.Write([]byte{b})
		}
		if d.Sum() != Sum(data) {
			t.Errorf("length %d mismatch", n)
		}
	}
}
