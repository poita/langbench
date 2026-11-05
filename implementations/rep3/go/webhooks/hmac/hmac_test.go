package hmac

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestRFC4231(t *testing.T) {
	cases := []struct{ key, msg, want string }{
		{"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"},
		{"Jefe", "what do ya want for nothing?", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"},
	}
	for _, c := range cases {
		key := []byte(c.key)
		if c.key[0] == '0' {
			key, _ = hex.DecodeString(c.key)
		}
		got := Sum256(key, []byte(c.msg))
		if hex.EncodeToString(got[:]) != c.want {
			t.Errorf("HMAC(%q) = %x", c.msg, got)
		}
	}
}

func TestLongKeyAndEmptyKey(t *testing.T) {
	// RFC 4231 test case 6: 131-byte key of 0xaa.
	key := bytes.Repeat([]byte{0xaa}, 131)
	got := Sum256(key, []byte("Test Using Larger Than Block-Size Key - Hash Key First"))
	if hex.EncodeToString(got[:]) != "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54" {
		t.Errorf("long key: %x", got)
	}
	got = Sum256(nil, nil)
	if hex.EncodeToString(got[:]) != "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad" {
		t.Errorf("empty key: %x", got)
	}
}

func TestPartsEqualConcatenation(t *testing.T) {
	k := NewKey([]byte("secret"))
	var a, b [Size]byte
	k.Sum(&a, []byte("hello"), []byte("."), []byte("world"))
	k.Sum(&b, []byte("hello.world"))
	if a != b {
		t.Fatal("streamed parts differ from concatenation")
	}
	// The key is reusable.
	var c [Size]byte
	k.Sum(&c, []byte("hello.world"))
	if b != c {
		t.Fatal("key not reusable")
	}
}

func TestEqual(t *testing.T) {
	if !Equal([]byte("ab"), []byte("ab")) || Equal([]byte("ab"), []byte("ac")) || Equal([]byte("a"), []byte("ab")) {
		t.Fatal("Equal wrong")
	}
}
