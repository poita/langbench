package hmac_test

import (
	stdhmac "crypto/hmac" // oracle only
	stdsha "crypto/sha256"
	"encoding/hex"
	"math/rand"
	"testing"

	"example.com/webhooks/hmac"
)

func TestRFC4231Case1(t *testing.T) {
	key := make([]byte, 20)
	for i := range key {
		key[i] = 0x0b
	}
	got := hmac.Sum256(key, []byte("Hi There"))
	if want := "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"; hex.EncodeToString(got[:]) != want {
		t.Fatalf("got %x want %s", got, want)
	}
}

func TestEmptyKeyAndMessage(t *testing.T) {
	got := hmac.Sum256(nil, nil)
	if want := "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"; hex.EncodeToString(got[:]) != want {
		t.Fatalf("got %x want %s", got, want)
	}
}

func TestMatchesStdlibAcrossKeyLengths(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	for _, kl := range []int{0, 1, 31, 32, 63, 64, 65, 100, 200} {
		key := make([]byte, kl)
		rng.Read(key)
		msg := make([]byte, rng.Intn(300))
		rng.Read(msg)
		m := stdhmac.New(stdsha.New, key)
		m.Write(msg)
		var want [32]byte
		copy(want[:], m.Sum(nil))
		if got := hmac.Sum256(key, msg); got != want {
			t.Errorf("keylen %d: got %x want %x", kl, got, want)
		}
	}
}

func TestSumStreamsPartsAndKeyIsReusable(t *testing.T) {
	k := hmac.NewKey([]byte("key"))
	whole := k.Sum([]byte("hello world"))
	if parts := k.Sum([]byte("hello"), []byte(" "), []byte("world")); parts != whole {
		t.Fatal("parts differ from whole")
	}
	if again := k.Sum([]byte("hello world")); again != whole {
		t.Fatal("key state was mutated")
	}
}

func TestEqual(t *testing.T) {
	if !hmac.Equal([]byte{1, 2}, []byte{1, 2}) || hmac.Equal([]byte{1, 2}, []byte{1, 3}) || hmac.Equal([]byte{1}, []byte{1, 2}) {
		t.Fatal("Equal misbehaves")
	}
}
