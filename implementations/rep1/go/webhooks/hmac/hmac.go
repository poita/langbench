// Package hmac implements HMAC-SHA-256 (RFC 2104) on top of the sibling
// sha256 package.
package hmac

import "example.com/webhooks/sha256"

// Size is the length of a MAC in bytes.
const Size = sha256.Size

// Sum returns HMAC-SHA-256 of the concatenation of parts under key. Passing
// the message in parts avoids having to join them first. Any key length,
// including zero, is accepted.
func Sum(key []byte, parts ...[]byte) [Size]byte {
	var k [sha256.BlockSize]byte
	if len(key) > sha256.BlockSize {
		sum := sha256.Sum256(key)
		copy(k[:], sum[:])
	} else {
		copy(k[:], key)
	}
	var ipad, opad [sha256.BlockSize]byte
	for i := range k {
		ipad[i] = k[i] ^ 0x36
		opad[i] = k[i] ^ 0x5c
	}
	inner := sha256.New()
	inner.Write(ipad[:])
	for _, p := range parts {
		inner.Write(p)
	}
	is := inner.Sum()
	outer := sha256.New()
	outer.Write(opad[:])
	outer.Write(is[:])
	return outer.Sum()
}

// Equal reports whether two MACs are equal, in time independent of where
// they first differ.
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
