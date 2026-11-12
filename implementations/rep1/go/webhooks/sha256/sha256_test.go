package sha256

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestSum256(t *testing.T) {
	tests := []struct{ in, want string }{
		{"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		{"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
		{"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"},
		{strings.Repeat("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
	}
	for _, tc := range tests {
		got := Sum256([]byte(tc.in))
		if h := hex.EncodeToString(got[:]); h != tc.want {
			n := len(tc.in)
			if n > 20 {
				n = 20
			}
			t.Errorf("Sum256(%q...) = %s, want %s", tc.in[:n], h, tc.want)
		}
	}
}

// Writing in arbitrary chunk sizes must not change the digest.
func TestStreamingChunks(t *testing.T) {
	data := []byte(strings.Repeat("0123456789abcdef", 50))
	want := Sum256(data)
	for chunk := 1; chunk <= 130; chunk++ {
		d := New()
		for i := 0; i < len(data); i += chunk {
			end := i + chunk
			if end > len(data) {
				end = len(data)
			}
			d.Write(data[i:end])
		}
		if got := d.Sum(); got != want {
			t.Fatalf("chunk size %d: digest mismatch", chunk)
		}
	}
}

func TestSumDoesNotMutate(t *testing.T) {
	d := New()
	d.Write([]byte("ab"))
	d.Sum()
	d.Write([]byte("c"))
	want := Sum256([]byte("abc"))
	if got := d.Sum(); got != want {
		t.Fatal("Sum changed the running state")
	}
}

// Padding changes shape at 55, 56 and 64 bytes; digests must be distinct
// and stable across lengths around those boundaries.
func TestPaddingBoundaries(t *testing.T) {
	seen := map[[Size]byte]int{}
	for n := 50; n <= 130; n++ {
		s := Sum256([]byte(strings.Repeat("x", n)))
		if prev, dup := seen[s]; dup {
			t.Fatalf("lengths %d and %d collide", prev, n)
		}
		seen[s] = n
	}
}
