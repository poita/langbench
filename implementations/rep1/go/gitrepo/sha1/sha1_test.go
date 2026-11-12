package sha1

import (
	csha1 "crypto/sha1" // oracle, tests only
	"encoding/hex"
	"math/rand"
	"testing"
)

func TestKnownVectors(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"", "da39a3ee5e6b4b0d3255bfef95601890afd80709"},
		{"abc", "a9993e364706816aba3e25717850c26c9cd0d89d"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"},
		{"blob 9\x00one file\n", "b7814cae2e925fe74c6cd5816462fff515ccb256"},
	} {
		got := Sum([]byte(tc.in))
		if hex.EncodeToString(got[:]) != tc.want {
			t.Errorf("Sum(%q) = %x, want %s", tc.in, got, tc.want)
		}
	}
}

func TestMatchesStandardLibrary(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for n := 0; n < 300; n++ {
		buf := make([]byte, n)
		rng.Read(buf)
		if got, want := Sum(buf), csha1.Sum(buf); got != want {
			t.Fatalf("length %d: got %x, want %x", n, got, want)
		}
	}
}

func TestStreamingChunks(t *testing.T) {
	data := make([]byte, 1000)
	rand.New(rand.NewSource(2)).Read(data)
	want := csha1.Sum(data)
	for _, chunk := range []int{1, 7, 63, 64, 65, 200} {
		d := New()
		for p := data; len(p) > 0; {
			n := min(chunk, len(p))
			d.Write(p[:n])
			p = p[n:]
		}
		if got := d.Sum(nil); hex.EncodeToString(got) != hex.EncodeToString(want[:]) {
			t.Errorf("chunk %d: got %x, want %x", chunk, got, want)
		}
	}
}

func TestSumDoesNotDisturbState(t *testing.T) {
	d := New()
	d.WriteString("ab")
	d.Sum(nil)
	d.WriteString("c")
	want := csha1.Sum([]byte("abc"))
	if got := d.Sum(nil); hex.EncodeToString(got) != hex.EncodeToString(want[:]) {
		t.Errorf("got %x, want %x", got, want)
	}
}

func BenchmarkSum1MiB(b *testing.B) {
	buf := make([]byte, 1<<20)
	b.SetBytes(int64(len(buf)))
	for i := 0; i < b.N; i++ {
		Sum(buf)
	}
}
