package sha256_test

import (
	"encoding/hex"
	"strings"
	"testing"

	"example.com/webhooks/sha256"
)

func TestSum256Vectors(t *testing.T) {
	tests := []struct{ in, want string }{
		{"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		{"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
		{strings.Repeat("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
	}
	for _, tc := range tests {
		got := sha256.Sum256([]byte(tc.in))
		if hex.EncodeToString(got[:]) != tc.want {
			t.Errorf("Sum256(len %d) = %x, want %s", len(tc.in), got, tc.want)
		}
	}
}

// Known digests around the padding boundaries (55, 56, 63, 64 bytes of 'a').
func TestBlockBoundaries(t *testing.T) {
	want := map[int]string{
		55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
		56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
		64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
	}
	for n, w := range want {
		got := sha256.Sum256([]byte(strings.Repeat("a", n)))
		if hex.EncodeToString(got[:]) != w {
			t.Errorf("len %d: got %x want %s", n, got, w)
		}
	}
}

// Incremental writes of every chunking must agree with the one-shot digest.
func TestIncremental(t *testing.T) {
	data := make([]byte, 300)
	for i := range data {
		data[i] = byte(i * 7)
	}
	want := sha256.Sum256(data)
	for chunk := 1; chunk <= 130; chunk++ {
		h := sha256.New()
		for i := 0; i < len(data); i += chunk {
			h.Write(data[i:min(i+chunk, len(data))])
		}
		if got := h.Sum(); got != want {
			t.Errorf("chunk %d: got %x want %x", chunk, got, want)
		}
	}
}

func TestWriteStringAndSumDoesNotMutate(t *testing.T) {
	h := sha256.New()
	h.WriteString(strings.Repeat("x", 100))
	first := h.Sum()
	if h.Sum() != first {
		t.Fatal("Sum changed state")
	}
	h.WriteString("y")
	if h.Sum() == first {
		t.Fatal("write after Sum ignored")
	}
	want := sha256.Sum256([]byte(strings.Repeat("x", 100) + "y"))
	if h.Sum() != want {
		t.Fatal("WriteString mismatch with Write")
	}
}

func TestCopySnapshot(t *testing.T) {
	h := sha256.New()
	h.Write([]byte("ab"))
	c := h
	c.Write([]byte("c"))
	if got := c.Sum(); hex.EncodeToString(got[:]) != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("copy: %x", got)
	}
	if h.Sum() != sha256.Sum256([]byte("ab")) {
		t.Fatal("original disturbed by copy")
	}
}
