// Package signature implements the Standard Webhooks signature scheme:
// secrets, signing and verification.
package signature

import (
	"errors"
	"strings"

	"example.com/webhooks/b64"
	"example.com/webhooks/hmac"
)

// SecretPrefix is the optional prefix of a secret string. It is removed once.
const SecretPrefix = "whsec_"

// ErrInvalidSecret is returned for a secret that is not valid Base64 after
// removing the prefix, or that decodes to zero bytes.
var ErrInvalidSecret = errors.New("signature: invalid secret")

// Secret is a parsed signing secret: the raw HMAC key plus its precomputed
// HMAC state. Create one with ParseSecret or NewSecret.
type Secret struct {
	raw []byte
	key hmac.Key
}

// ParseSecret parses a secret string such as "whsec_MfKQ9r8G...". A single
// leading "whsec_" is removed and the rest is Base64-decoded (either alphabet,
// padding optional) to give the key, which must be non-empty.
func ParseSecret(s string) (*Secret, error) {
	s = strings.TrimPrefix(s, SecretPrefix)
	raw, err := b64.Decode(s)
	if err != nil || len(raw) == 0 {
		return nil, ErrInvalidSecret
	}
	return NewSecret(raw)
}

// NewSecret builds a Secret directly from raw key bytes, which must not be
// empty.
func NewSecret(raw []byte) (*Secret, error) {
	if len(raw) == 0 {
		return nil, ErrInvalidSecret
	}
	raw = append([]byte(nil), raw...)
	return &Secret{raw: raw, key: hmac.NewKey(raw)}, nil
}

// Key returns a copy of the raw key bytes.
func (s *Secret) Key() []byte { return append([]byte(nil), s.raw...) }

// mac computes HMAC(key, id "." ts "." body), streaming the parts.
func (s *Secret) mac(id, ts string, body []byte) [hmac.Size]byte {
	m := s.key.New()
	m.WriteString(id)
	m.WriteString(".")
	m.WriteString(ts)
	m.WriteString(".")
	m.Write(body)
	return m.Sum()
}
