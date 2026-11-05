package signature

import (
	"strings"

	"example.com/webhooks/b64"
	"example.com/webhooks/hmac"
)

// Tolerance is the allowed clock difference, in seconds, between the message
// timestamp and the verifier's clock. The bound is inclusive.
const Tolerance = 300

// MaxTimestamp is the largest absolute timestamp value accepted.
const MaxTimestamp = 1_000_000_000_000_000

// Reason says why verification failed. It implements error.
type Reason string

// Verification failure reasons, in the order the checks are performed.
const (
	MissingSignature Reason = "missing-signature"
	InvalidTimestamp Reason = "invalid-timestamp"
	TimestampTooOld  Reason = "timestamp-too-old"
	TimestampTooNew  Reason = "timestamp-too-new"
	NoMatch          Reason = "no-match"
)

func (r Reason) Error() string { return string(r) }

// Match identifies the signature that verified: the index of the secret and
// the index of the header token (counting every space-separated token,
// including empty ones).
type Match struct {
	Secret int
	Token  int
}

// ParseTimestamp parses a canonical decimal integer: "0", or an optional "-"
// followed by a digit 1-9 and more digits, with absolute value at most
// MaxTimestamp. It reports false for anything else (including "+5", "007",
// "-0", "1e3" and the empty string).
func ParseTimestamp(s string) (int64, bool) {
	neg := false
	d := s
	if strings.HasPrefix(d, "-") {
		neg, d = true, d[1:]
	}
	if len(d) == 0 || len(d) > 16 {
		return 0, false
	}
	if d[0] == '0' {
		if len(d) == 1 && !neg {
			return 0, true
		}
		return 0, false
	}
	var v int64
	for i := 0; i < len(d); i++ {
		c := d[i]
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

type candidate struct {
	token int
	mac   [hmac.Size]byte
}

// Verify checks a received webhook. header is the webhook-signature value
// (space-separated tokens), id and ts the webhook-id and webhook-timestamp
// values as received, and now the verifier's clock in Unix seconds.
//
// On success it returns the first matching (secret, token) pair, secrets
// taking precedence over tokens. On failure the error is a Reason.
func Verify(secrets []*Secret, id, ts, header string, body []byte, now int64) (Match, error) {
	if strings.Trim(header, " ") == "" {
		return Match{}, MissingSignature
	}
	t, ok := ParseTimestamp(ts)
	if !ok {
		return Match{}, InvalidTimestamp
	}
	if now-t > Tolerance {
		return Match{}, TimestampTooOld
	}
	if t-now > Tolerance {
		return Match{}, TimestampTooNew
	}

	// Decode every token once; only "v1,<32 bytes of base64>" can ever match.
	var cands []candidate
	var scratch []byte
	rest, idx := header, 0
	for {
		tok := rest
		end := strings.IndexByte(rest, ' ')
		if end >= 0 {
			tok = rest[:end]
		}
		if comma := strings.IndexByte(tok, ','); comma >= 0 && tok[:comma] == Version {
			var err error
			scratch, err = b64.AppendDecode(scratch[:0], tok[comma+1:])
			if err == nil && len(scratch) == hmac.Size {
				c := candidate{token: idx}
				copy(c.mac[:], scratch)
				cands = append(cands, c)
			}
		}
		if end < 0 {
			break
		}
		rest = rest[end+1:]
		idx++
	}
	if len(cands) == 0 {
		return Match{}, NoMatch
	}
	for i, s := range secrets {
		want := s.mac(id, ts, body)
		for _, c := range cands {
			if hmac.Equal(want[:], c.mac[:]) {
				return Match{Secret: i, Token: c.token}, nil
			}
		}
	}
	return Match{}, NoMatch
}
