// Package hmac implements HMAC-SHA-256 (RFC 2104) on top of the sha256
// package in this module.
//
// A Key is derived once from raw key bytes: it stores the hasher states after
// absorbing key^ipad and key^opad. Each MAC then copies those states and
// streams the message through them, so neither the key schedule nor the
// message is ever concatenated or recomputed.
package hmac

import "example.com/webhooks/sha256"

// Size is the size of an HMAC-SHA-256 tag in bytes.
const Size = sha256.Size

// Key is a precomputed HMAC-SHA-256 key. It is immutable after NewKey and
// safe for concurrent use.
type Key struct {
	inner, outer sha256.Hasher
}

// NewKey builds a Key from raw key bytes of any length (including zero).
func NewKey(key []byte) *Key {
	var padded [sha256.BlockSize]byte
	if len(key) > sha256.BlockSize {
		sum := sha256.Sum256(key)
		copy(padded[:], sum[:])
	} else {
		copy(padded[:], key)
	}
	var ipad, opad [sha256.BlockSize]byte
	for i, b := range padded {
		ipad[i] = b ^ 0x36
		opad[i] = b ^ 0x5c
	}
	k := &Key{inner: sha256.New(), outer: sha256.New()}
	k.inner.Write(ipad[:])
	k.outer.Write(opad[:])
	return k
}

// Sum returns the tag over the concatenation of parts, streaming each part
// without building the concatenated message.
func (k *Key) Sum(parts ...[]byte) [Size]byte {
	in := k.inner
	for _, p := range parts {
		in.Write(p)
	}
	digest := in.Sum()
	out := k.outer
	out.Write(digest[:])
	return out.Sum()
}

// Sum256 returns HMAC-SHA-256(key, msg) in one call.
func Sum256(key, msg []byte) [Size]byte {
	return NewKey(key).Sum(msg)
}

// Equal reports whether two tags are equal, in time independent of where they
// differ.
func Equal(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := range a {
		v |= a[i] ^ b[i]
	}
	return v == 0
}
