package sha256

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestSum256Vectors(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		{"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
		{strings.Repeat("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
	}
	for _, c := range cases {
		got := Sum256([]byte(c.in))
		if hex.EncodeToString(got[:]) != c.want {
			t.Errorf("Sum256(len %d) = %x, want %s", len(c.in), got, c.want)
		}
	}
}

func TestIncrementalMatchesOneShot(t *testing.T) {
	msg := []byte(strings.Repeat("0123456789abcdef", 40))
	for n := 0; n <= len(msg); n += 7 {
		want := Sum256(msg[:n])
		for _, step := range []int{1, 3, 63, 64, 65, 200} {
			d := New()
			for i := 0; i < n; i += step {
				end := min(i+step, n)
				d.Write(msg[i:end])
			}
			var got [Size]byte
			d.Sum(&got)
			if got != want {
				t.Fatalf("n=%d step=%d: incremental mismatch", n, step)
			}
		}
	}
}

func TestPaddingBoundaries(t *testing.T) {
	// Lengths around 55/56/63/64 exercise one- and two-block padding.
	known := map[int]string{
		55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
		56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
		64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
	}
	for n, want := range known {
		got := Sum256([]byte(strings.Repeat("a", n)))
		if hex.EncodeToString(got[:]) != want {
			t.Errorf("len %d: got %x want %s", n, got, want)
		}
	}
}

func TestSumDoesNotChangeState(t *testing.T) {
	d := New()
	d.Write([]byte("ab"))
	var first, second [Size]byte
	d.Sum(&first)
	d.Write([]byte("c"))
	d.Sum(&second)
	if first != Sum256([]byte("ab")) || second != Sum256([]byte("abc")) {
		t.Fatal("Sum must be non-destructive")
	}
}

func TestCopySnapshotsState(t *testing.T) {
	d := New()
	d.Write([]byte("a"))
	c := d
	c.Write([]byte("bc"))
	var got [Size]byte
	d.Write([]byte("bc"))
	d.Sum(&got)
	if got != Sum256([]byte("abc")) {
		t.Fatal("copy altered original")
	}
}
