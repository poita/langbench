// Package signature implements the Standard Webhooks signing scheme: secret
// parsing, producing the webhook-signature header and verifying a received
// delivery.
package signature

import (
	"errors"
	"strings"

	"example.com/webhooks/base64"
	"example.com/webhooks/hmac"
)

// SecretPrefix is the optional prefix of a secret string.
const SecretPrefix = "whsec_"

// Tolerance is the maximum clock difference, in seconds, accepted between the
// message timestamp and the verifier's clock. The bound is inclusive.
const Tolerance = 300

// MaxTimestamp bounds the absolute value of a canonical timestamp.
const MaxTimestamp = 1_000_000_000_000_000

// Verification failure reasons. Each error's text is the stable reason word
// used by the command-line tool.
var (
	ErrMissingSignature = errors.New("missing-signature")
	ErrInvalidTimestamp = errors.New("invalid-timestamp")
	ErrTimestampTooOld  = errors.New("timestamp-too-old")
	ErrTimestampTooNew  = errors.New("timestamp-too-new")
	ErrNoMatch          = errors.New("no-match")
)

// ErrInvalidSecret is returned by ParseSecret.
var ErrInvalidSecret = errors.New("signature: invalid secret")

// DecodeSecret returns the raw key bytes of a secret string. One leading
// "whsec_" is removed; the rest must be valid Base64 (either alphabet, padding
// optional) decoding to at least one byte.
func DecodeSecret(s string) ([]byte, error) {
	s = strings.TrimPrefix(s, SecretPrefix)
	raw, err := base64.Decode([]byte(s))
	if err != nil || len(raw) == 0 {
		return nil, ErrInvalidSecret
	}
	return raw, nil
}

// ParseSecret decodes a secret string (see DecodeSecret) into an HMAC key.
func ParseSecret(s string) (*hmac.Key, error) {
	raw, err := DecodeSecret(s)
	if err != nil {
		return nil, err
	}
	return hmac.NewKey(raw), nil
}

// ParseTimestamp parses a canonical decimal integer: "0", or an optional "-"
// followed by a non-zero digit and more digits, with absolute value at most
// MaxTimestamp. ok is false for anything else.
func ParseTimestamp(s []byte) (v int64, ok bool) {
	i := 0
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		i = 1
	}
	digits := s[i:]
	if len(digits) == 0 || len(digits) > 16 {
		return 0, false
	}
	if digits[0] == '0' && (len(digits) > 1 || neg) {
		return 0, false
	}
	for _, c := range digits {
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

// AppendSignature appends the webhook-signature header value for the message
// to dst: one "v1,<base64>" per key, in order, joined by single spaces. ts
// must be the timestamp text exactly as it is sent in the webhook-timestamp
// header. The signed content id "." ts "." body is streamed, never built.
func AppendSignature(dst []byte, keys []*hmac.Key, id, ts string, body []byte) []byte {
	idb, tsb := []byte(id), []byte(ts)
	dot := []byte{'.'}
	for i, k := range keys {
		if i > 0 {
			dst = append(dst, ' ')
		}
		mac := k.Sum(idb, dot, tsb, dot, body)
		dst = append(dst, "v1,"...)
		dst = base64.AppendStandard(dst, mac[:])
	}
	return dst
}

// Sign returns the webhook-signature header value; see AppendSignature.
func Sign(keys []*hmac.Key, id, ts string, body []byte) string {
	return string(AppendSignature(nil, keys, id, ts, body))
}

// Match identifies the secret and header token that verified a message. Both
// are 0-based; Token counts every space-separated token of the header,
// including empty ones.
type Match struct {
	Secret, Token int
}

// Verify checks a received message. keys are the active secrets in order, id,
// ts and header the received webhook-id, webhook-timestamp and
// webhook-signature values, and now the verifier's Unix time in seconds.
//
// On failure the error is one of the Err* reason values above.
func Verify(keys []*hmac.Key, id, ts string, header, body []byte, now int64) (Match, error) {
	// 1. At least one non-empty token.
	allEmpty := true
	for _, c := range header {
		if c != ' ' {
			allEmpty = false
			break
		}
	}
	if allEmpty {
		return Match{}, ErrMissingSignature
	}
	// 2. Timestamp syntax.
	t, ok := ParseTimestamp([]byte(ts))
	if !ok {
		return Match{}, ErrInvalidTimestamp
	}
	// 3. Tolerance window.
	if now-t > Tolerance {
		return Match{}, ErrTimestampTooOld
	}
	if t-now > Tolerance {
		return Match{}, ErrTimestampTooNew
	}
	// 4. Decode every token once; only "v1,<32 decoded bytes>" can match.
	type candidate struct {
		token int
		mac   [hmac.Size]byte
	}
	var cands []candidate
	var scratch []byte
	for j, start := 0, 0; start <= len(header); j++ {
		end := start
		for end < len(header) && header[end] != ' ' {
			end++
		}
		tok := header[start:end]
		start = end + 1
		comma := -1
		for i, c := range tok {
			if c == ',' {
				comma = i
				break
			}
		}
		if comma != 2 || tok[0] != 'v' || tok[1] != '1' {
			continue
		}
		var err error
		scratch, err = base64.AppendDecode(scratch[:0], tok[comma+1:])
		if err != nil || len(scratch) != hmac.Size {
			continue
		}
		c := candidate{token: j}
		copy(c.mac[:], scratch)
		cands = append(cands, c)
	}
	// 5. One MAC per secret, compared against the pre-decoded tokens.
	if len(cands) > 0 {
		idb, tsb, dot := []byte(id), []byte(ts), []byte{'.'}
		for i, k := range keys {
			mac := k.Sum(idb, dot, tsb, dot, body)
			for _, c := range cands {
				if hmac.Equal(mac[:], c.mac[:]) {
					return Match{Secret: i, Token: c.token}, nil
				}
			}
		}
	}
	return Match{}, ErrNoMatch
}
