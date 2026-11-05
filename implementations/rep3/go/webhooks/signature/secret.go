// Package signature implements the Standard Webhooks signature scheme:
// secrets, signing and verification.
package signature

import (
	"errors"

	"webhooks/base64"
	"webhooks/hmac"
)

// Limits on secrets and on the identifiers that are signed.
const (
	MaxSecretLen  = 512
	MaxSecrets    = 16
	MaxIDLen      = 256
	MaxTimestamp  = 1_000_000_000_000_000 // 10^15
	secretPrefix  = "whsec_"
	maxTimestampL = 64
)

// ErrInvalidSecret is returned for a malformed secret.
var ErrInvalidSecret = errors.New("signature: invalid secret")

// Secret is a parsed signing secret: the raw key and its precomputed HMAC
// state. Secrets are values; copying one is cheap and safe.
type Secret struct {
	// Raw is the decoded key (never empty).
	Raw []byte
	key hmac.Key
}

// ParseSecret parses one secret: 1..512 printable ASCII characters other than
// ',', with one optional "whsec_" prefix removed, whose remainder is valid
// non-empty Base64.
func ParseSecret(s []byte) (Secret, error) {
	if len(s) == 0 || len(s) > MaxSecretLen {
		return Secret{}, ErrInvalidSecret
	}
	for _, c := range s {
		if c < 0x21 || c > 0x7e || c == ',' {
			return Secret{}, ErrInvalidSecret
		}
	}
	if len(s) >= len(secretPrefix) && string(s[:len(secretPrefix)]) == secretPrefix {
		s = s[len(secretPrefix):]
	}
	raw, err := base64.Decode(nil, s)
	if err != nil || len(raw) == 0 {
		return Secret{}, ErrInvalidSecret
	}
	return Secret{Raw: raw, key: hmac.NewKey(raw)}, nil
}

// ParseSecrets parses a comma-separated list of 1..16 secrets.
func ParseSecrets(field []byte) ([]Secret, error) {
	var out []Secret
	for {
		i := 0
		for i < len(field) && field[i] != ',' {
			i++
		}
		if len(out) == MaxSecrets {
			return nil, ErrInvalidSecret
		}
		sec, err := ParseSecret(field[:i])
		if err != nil {
			return nil, err
		}
		out = append(out, sec)
		if i == len(field) {
			return out, nil
		}
		field = field[i+1:]
	}
}

// MAC computes HMAC-SHA-256(key, id "." ts "." body) into out, streaming the
// parts without building the concatenated message.
func (s *Secret) MAC(out *[hmac.Size]byte, id, ts, body []byte) {
	s.key.Sum(out, id, dot, ts, dot, body)
}

var dot = []byte{'.'}

// ParseTimestamp parses a canonical decimal integer: "0", or an optional '-'
// followed by a digit 1-9 and further digits, with absolute value at most 10^15.
func ParseTimestamp(b []byte) (int64, bool) {
	neg := false
	if len(b) > 0 && b[0] == '-' {
		neg = true
		b = b[1:]
	}
	if len(b) == 0 || len(b) > 16 {
		return 0, false
	}
	if b[0] == '0' && (len(b) > 1 || neg) {
		return 0, false
	}
	var v int64
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int64(c-'0')
	}
	if v > MaxTimestamp {
		return 0, false
	}
	if neg {
		v = -v
	}
	return v, true
}

// ValidID reports whether b is 1..256 printable ASCII characters without space.
func ValidID(b []byte) bool {
	if len(b) == 0 || len(b) > MaxIDLen {
		return false
	}
	for _, c := range b {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}

// ValidTimestampText reports whether b is acceptable as received timestamp
// text: 1..64 printable ASCII characters without space.
func ValidTimestampText(b []byte) bool {
	if len(b) == 0 || len(b) > maxTimestampL {
		return false
	}
	for _, c := range b {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}
