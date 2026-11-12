package hmac

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestSum(t *testing.T) {
	long := bytes.Repeat([]byte{0xaa}, 131)
	tests := []struct {
		name     string
		key, msg []byte
		want     string
	}{
		{"rfc4231-1", bytes.Repeat([]byte{0x0b}, 20), []byte("Hi There"),
			"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"},
		{"rfc4231-2", []byte("Jefe"), []byte("what do ya want for nothing?"),
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"},
		{"rfc4231-6-long-key", long, []byte("Test Using Larger Than Block-Size Key - Hash Key First"),
			"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"},
		{"empty", nil, nil,
			"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"},
	}
	for _, tc := range tests {
		got := Sum(tc.key, tc.msg)
		if h := hex.EncodeToString(got[:]); h != tc.want {
			t.Errorf("%s: got %s, want %s", tc.name, h, tc.want)
		}
	}
}

func TestPartsEqualJoined(t *testing.T) {
	a := Sum([]byte("k"), []byte("hello "), []byte("world"))
	b := Sum([]byte("k"), []byte("hello world"))
	if a != b {
		t.Fatal("splitting the message changed the MAC")
	}
}

func TestEqual(t *testing.T) {
	if !Equal([]byte{1, 2}, []byte{1, 2}) || Equal([]byte{1, 2}, []byte{1, 3}) || Equal([]byte{1}, []byte{1, 2}) {
		t.Fatal("Equal misbehaves")
	}
}
