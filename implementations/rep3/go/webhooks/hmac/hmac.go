// Package hmac implements HMAC-SHA-256 (RFC 2104) on top of package sha256.
//
// A Key holds the SHA-256 states left after absorbing the ipad and opad
// blocks, so each MAC only pays for the message and two finishing steps. The
// message is passed as parts that are streamed through the hasher and never
// concatenated.
package hmac

import "webhooks/sha256"

// Size is the size of a MAC in bytes.
const Size = sha256.Size

// Key is a precomputed HMAC-SHA-256 key. It contains no pointers and may be
// copied freely. The zero Key is not valid; use NewKey.
type Key struct {
	inner, outer sha256.Digest
}

// NewKey derives the HMAC state for key. Keys of any length, including zero,
// are accepted.
func NewKey(key []byte) Key {
	var block [sha256.BlockSize]byte
	if len(key) > sha256.BlockSize {
		sum := sha256.Sum256(key)
		copy(block[:], sum[:])
	} else {
		copy(block[:], key)
	}
	var ipad, opad [sha256.BlockSize]byte
	for i, b := range block {
		ipad[i] = b ^ 0x36
		opad[i] = b ^ 0x5c
	}
	k := Key{inner: sha256.New(), outer: sha256.New()}
	k.inner.Write(ipad[:])
	k.outer.Write(opad[:])
	return k
}

// Sum computes the MAC of the concatenation of parts into out.
func (k *Key) Sum(out *[Size]byte, parts ...[]byte) {
	in := k.inner
	for _, p := range parts {
		in.Write(p)
	}
	var digest [sha256.Size]byte
	in.Sum(&digest)
	o := k.outer
	o.Write(digest[:])
	o.Sum(out)
}

// Sum256 returns HMAC-SHA-256(key, msg).
func Sum256(key, msg []byte) [Size]byte {
	k := NewKey(key)
	var out [Size]byte
	k.Sum(&out, msg)
	return out
}

// Equal reports whether a and b are equal, in time that depends only on their
// lengths.
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
