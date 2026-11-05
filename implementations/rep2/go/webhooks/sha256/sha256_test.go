package sha256_test

import (
	stdsha "crypto/sha256" // oracle only: used to cross-check, never by the library
	"encoding/hex"
	"math/rand"
	"testing"

	"example.com/webhooks/sha256"
)

func TestKnownVectors(t *testing.T) {
	cases := map[string]string{
		"":    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq": "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
	}
	for in, want := range cases {
		got := sha256.Sum256([]byte(in))
		if hex.EncodeToString(got[:]) != want {
			t.Errorf("Sum256(%q) = %x, want %s", in, got, want)
		}
	}
}

func TestMatchesStdlibAtAllBoundaries(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	data := make([]byte, 600)
	rng.Read(data)
	for n := 0; n <= len(data); n++ {
		want := stdsha.Sum256(data[:n])
		if got := sha256.Sum256(data[:n]); got != want {
			t.Fatalf("len %d: got %x want %x", n, got, want)
		}
	}
}

func TestIncrementalWritesAnyChunking(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	data := make([]byte, 1000)
	rng.Read(data)
	want := stdsha.Sum256(data)
	for trial := 0; trial < 50; trial++ {
		h := sha256.New()
		rest := data
		for len(rest) > 0 {
			n := rng.Intn(150) + 1
			if n > len(rest) {
				n = len(rest)
			}
			h.Write(rest[:n])
			rest = rest[n:]
		}
		if got := h.Sum(); got != want {
			t.Fatalf("trial %d: got %x want %x", trial, got, want)
		}
	}
}

func TestSumDoesNotChangeState(t *testing.T) {
	h := sha256.New()
	h.Write([]byte("ab"))
	_ = h.Sum()
	h.Write([]byte("c"))
	if got, want := h.Sum(), sha256.Sum256([]byte("abc")); got != want {
		t.Fatalf("got %x want %x", got, want)
	}
}

func TestCopySnapshotsState(t *testing.T) {
	h := sha256.New()
	h.Write([]byte("prefix-"))
	c := h
	h.Write([]byte("one"))
	c.Write([]byte("two"))
	if h.Sum() != sha256.Sum256([]byte("prefix-one")) || c.Sum() != sha256.Sum256([]byte("prefix-two")) {
		t.Fatal("copies are not independent")
	}
}
