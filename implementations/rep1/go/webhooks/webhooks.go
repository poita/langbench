// Package webhooks implements the Standard Webhooks signature scheme: secret
// parsing, signing and verification of webhook deliveries.
//
// The cryptographic primitives (SHA-256, HMAC, Base64) come from the sibling
// packages sha256, hmac and b64; nothing here relies on the standard library
// crypto packages.
//
// A delivery is signed over "<id>.<timestamp>.<body>" and the signature is
// carried in the webhook-signature header as "v1,<base64 mac>". Several
// signatures, one per active secret, are joined by single spaces to support
// key rotation.
package webhooks

import (
	"errors"
	"strings"

	"example.com/webhooks/b64"
	"example.com/webhooks/hmac"
)

const (
	// SecretPrefix is the optional prefix of a secret string.
	SecretPrefix = "whsec_"
	// Version is the only signature version understood.
	Version = "v1"
	// Tolerance is the largest accepted clock difference, in seconds
	// (inclusive), between a message timestamp and the verifier's clock.
	Tolerance = 300
	// MaxTimestamp bounds the absolute value of a timestamp.
	MaxTimestamp = 1_000_000_000_000_000
)

// ErrInvalidSecret is returned by ParseSecret.
var ErrInvalidSecret = errors.New("webhooks: invalid secret")

// ErrInvalidInteger is returned by ParseInt.
var ErrInvalidInteger = errors.New("webhooks: not a canonical integer")

// Verification failures. The Error text of each is the stable
// machine-readable reason.
var (
	ErrMissingSignature = errors.New("missing-signature")
	ErrInvalidTimestamp = errors.New("invalid-timestamp")
	ErrTimestampTooOld  = errors.New("timestamp-too-old")
	ErrTimestampTooNew  = errors.New("timestamp-too-new")
	ErrNoMatch          = errors.New("no-match")
)

// ParseSecret turns a secret string into the raw HMAC key. One leading
// "whsec_" is removed, and the rest is Base64-decoded (either alphabet,
// padding optional). A secret that is not valid Base64 or decodes to no
// bytes is rejected.
func ParseSecret(s string) ([]byte, error) {
	s = strings.TrimPrefix(s, SecretPrefix)
	key, err := b64.Decode(s)
	if err != nil || len(key) == 0 {
		return nil, ErrInvalidSecret
	}
	return key, nil
}

// ParseInt parses a canonical decimal integer: "0", or an optional '-'
// followed by a digit 1-9 and further digits, with absolute value at most
// MaxTimestamp. Forms such as "+5", "007", "-0" or "1e3" are rejected.
func ParseInt(s string) (int64, error) {
	i := 0
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i++
	}
	digits := s[i:]
	if len(digits) == 0 || len(digits) > 16 {
		return 0, ErrInvalidInteger
	}
	if digits[0] == '0' && (len(digits) > 1 || neg) {
		return 0, ErrInvalidInteger
	}
	var v int64
	for j := 0; j < len(digits); j++ {
		c := digits[j]
		if c < '0' || c > '9' {
			return 0, ErrInvalidInteger
		}
		v = v*10 + int64(c-'0')
	}
	if v > MaxTimestamp {
		return 0, ErrInvalidInteger
	}
	if neg {
		v = -v
	}
	return v, nil
}

// mac computes the signature of a message for one key.
func mac(key []byte, id, ts string, body []byte) [hmac.Size]byte {
	return hmac.Sum(key, []byte(id), []byte("."), []byte(ts), []byte("."), body)
}

// Sign returns the "v1,<base64>" signature of a delivery under one key. ts is
// the timestamp text exactly as it is sent in the webhook-timestamp header.
func Sign(key []byte, id, ts string, body []byte) string {
	m := mac(key, id, ts, body)
	return Version + "," + b64.EncodeStd(m[:])
}

// SignHeader returns the webhook-signature header value for the given keys:
// one signature per key in order, joined by single spaces.
func SignHeader(keys [][]byte, id, ts string, body []byte) string {
	var sb strings.Builder
	for i, k := range keys {
		if i > 0 {
			sb.WriteByte(' ')
		}
		sb.WriteString(Sign(k, id, ts, body))
	}
	return sb.String()
}

// Match identifies the signature that verified a message.
type Match struct {
	Secret int // index into the keys slice
	Token  int // index of the space-separated header token
}

// Verify checks a received delivery against the active keys at time now (Unix
// seconds). It returns the first matching (key, token) pair, scanning keys in
// order and, within a key, header tokens in order. On failure the error is one
// of ErrMissingSignature, ErrInvalidTimestamp, ErrTimestampTooOld,
// ErrTimestampTooNew or ErrNoMatch, checked in that order.
//
// One MAC is computed per key; the cost is O(len(keys)·(len(body)+tokens)).
func Verify(keys [][]byte, id, ts, header string, body []byte, now int64) (Match, error) {
	tokens := strings.Split(header, " ")
	allEmpty := true
	for _, t := range tokens {
		if t != "" {
			allEmpty = false
			break
		}
	}
	if allEmpty {
		return Match{}, ErrMissingSignature
	}
	t, err := ParseInt(ts)
	if err != nil {
		return Match{}, ErrInvalidTimestamp
	}
	if now-t > Tolerance {
		return Match{}, ErrTimestampTooOld
	}
	if t-now > Tolerance {
		return Match{}, ErrTimestampTooNew
	}

	// Decode each v1 token once; sigs[j] is nil for tokens that cannot match.
	sigs := make([][]byte, len(tokens))
	for j, tok := range tokens {
		comma := strings.IndexByte(tok, ',')
		if comma < 0 || tok[:comma] != Version {
			continue
		}
		if raw, err := b64.Decode(tok[comma+1:]); err == nil {
			sigs[j] = raw
		}
	}
	for i, key := range keys {
		want := mac(key, id, ts, body)
		for j, got := range sigs {
			if got != nil && hmac.Equal(got, want[:]) {
				return Match{Secret: i, Token: j}, nil
			}
		}
	}
	return Match{}, ErrNoMatch
}
