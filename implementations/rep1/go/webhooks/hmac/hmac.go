// Package hmac implements HMAC-SHA-256 (RFC 2104) on top of package sha256.
//
// A Key precomputes the hasher states after absorbing the ipad and opad
// blocks, so each MAC over a message costs only the message blocks plus the
// final outer compression.
package hmac

import "example.com/webhooks/sha256"

// Size is the length of a MAC in bytes.
const Size = sha256.Size

// Key is an HMAC key prepared for repeated use. Create it with NewKey.
type Key struct {
	inner, outer sha256.Hasher
}

// NewKey prepares key (of any length, including zero) for use.
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

// MAC is an in-progress message authentication computation.
type MAC struct {
	inner sha256.Hasher
	outer sha256.Hasher
}

// New starts a MAC computation with this key. The key is not modified, so it
// may start any number of MACs.
func (k *Key) New() MAC {
	return MAC{inner: k.inner, outer: k.outer}
}

// Write absorbs p into the MAC. It never fails.
func (m *MAC) Write(p []byte) (int, error) { return m.inner.Write(p) }

// WriteString absorbs s into the MAC.
func (m *MAC) WriteString(s string) { m.inner.WriteString(s) }

// Sum finishes the computation and returns the 32-byte MAC. The MAC must not
// be used afterwards.
func (m *MAC) Sum() [Size]byte {
	in := m.inner.Sum()
	m.outer.Write(in[:])
	return m.outer.Sum()
}

// Sum256 returns HMAC-SHA-256(key, msg).
func Sum256(key, msg []byte) [Size]byte {
	k := NewKey(key)
	m := k.New()
	m.Write(msg)
	return m.Sum()
}

// Equal reports whether a and b are equal, examining every byte regardless of
// where they first differ.
func Equal(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
