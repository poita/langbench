package hmac_test

import (
	"bytes"
	"encoding/hex"
	"testing"

	"example.com/webhooks/hmac"
)

func TestRFC4231(t *testing.T) {
	tests := []struct {
		key, msg []byte
		want     string
	}{
		{bytes.Repeat([]byte{0x0b}, 20), []byte("Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"},
		{[]byte("Jefe"), []byte("what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"},
		{bytes.Repeat([]byte{0xaa}, 20), bytes.Repeat([]byte{0xdd}, 50), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"},
		// Key longer than the block size (test case 6).
		{bytes.Repeat([]byte{0xaa}, 131), []byte("Test Using Larger Than Block-Size Key - Hash Key First"), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"},
	}
	for i, tc := range tests {
		got := hmac.Sum256(tc.key, tc.msg)
		if hex.EncodeToString(got[:]) != tc.want {
			t.Errorf("case %d: got %x want %s", i, got, tc.want)
		}
	}
}

func TestEmptyKey(t *testing.T) {
	got := hmac.Sum256(nil, nil)
	if hex.EncodeToString(got[:]) != "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad" {
		t.Fatalf("got %x", got)
	}
}

func TestKeyReuseAndStreaming(t *testing.T) {
	k := hmac.NewKey([]byte("secret"))
	whole := hmac.Sum256([]byte("secret"), []byte("hello world"))
	for i := 0; i < 3; i++ { // the key must be reusable
		m := k.New()
		m.WriteString("hello")
		m.Write([]byte(" world"))
		if got := m.Sum(); got != whole {
			t.Fatalf("round %d: got %x want %x", i, got, whole)
		}
	}
}

func TestEqual(t *testing.T) {
	if !hmac.Equal([]byte("ab"), []byte("ab")) || hmac.Equal([]byte("ab"), []byte("ac")) || hmac.Equal([]byte("a"), []byte("ab")) {
		t.Fatal("Equal misbehaves")
	}
}
