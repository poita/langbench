package signature

import (
	"webhooks/base64"
	"webhooks/hmac"
)

// Tolerance is the allowed clock skew in seconds, inclusive in both directions.
const Tolerance = 300

// Reason says why verification failed.
type Reason string

// Failure reasons, in the order the checks are made.
const (
	MissingSignature Reason = "missing-signature"
	InvalidTimestamp Reason = "invalid-timestamp"
	TimestampTooOld  Reason = "timestamp-too-old"
	TimestampTooNew  Reason = "timestamp-too-new"
	NoMatch          Reason = "no-match"
)

// Result is the outcome of Verify.
type Result struct {
	OK bool
	// Secret and Token are the 0-based index of the matching secret and of the
	// matching space-separated header token (counting empty tokens); valid
	// only when OK.
	Secret, Token int
	// Reason is set when !OK.
	Reason Reason
}

type candidate struct {
	index int
	mac   [hmac.Size]byte
}

// Verify checks a received webhook against the active secrets. id, ts, header
// and body are exactly as received; now is the current Unix time in seconds.
func Verify(secrets []Secret, id, ts []byte, now int64, header, body []byte) Result {
	// 1. Header must have at least one non-empty token.
	empty := true
	for _, c := range header {
		if c != ' ' {
			empty = false
			break
		}
	}
	if empty {
		return Result{Reason: MissingSignature}
	}
	// 2. Timestamp must be canonical.
	t, ok := ParseTimestamp(ts)
	if !ok {
		return Result{Reason: InvalidTimestamp}
	}
	// 3. Tolerance window.
	if now-t > Tolerance {
		return Result{Reason: TimestampTooOld}
	}
	if t-now > Tolerance {
		return Result{Reason: TimestampTooNew}
	}
	// 4. Decode each token once; only "v1,<32 bytes>" tokens can match.
	var cands []candidate
	var buf [40]byte
	idx := 0
	for rest := header; ; idx++ {
		end := 0
		for end < len(rest) && rest[end] != ' ' {
			end++
		}
		if c, ok := decodeToken(rest[:end], buf[:0]); ok {
			cands = append(cands, candidate{index: idx, mac: c})
		}
		if end == len(rest) {
			break
		}
		rest = rest[end+1:]
	}
	if len(cands) > 0 {
		for i := range secrets {
			var mac [hmac.Size]byte
			secrets[i].MAC(&mac, id, ts, body)
			for j := range cands {
				if hmac.Equal(mac[:], cands[j].mac[:]) {
					return Result{OK: true, Secret: i, Token: cands[j].index}
				}
			}
		}
	}
	return Result{Reason: NoMatch}
}

// decodeToken returns the 32-byte MAC carried by a "v1,<base64>" token.
func decodeToken(tok, buf []byte) (mac [hmac.Size]byte, ok bool) {
	comma := -1
	for i, c := range tok {
		if c == ',' {
			comma = i
			break
		}
	}
	if comma != 2 || tok[0] != 'v' || tok[1] != '1' {
		return mac, false
	}
	value := tok[comma+1:]
	// 32 bytes encode to 43 characters, plus at most one '=' of padding.
	if len(value) < 43 || len(value) > 44 {
		return mac, false
	}
	raw, err := base64.Decode(buf, value)
	if err != nil || len(raw) != hmac.Size {
		return mac, false
	}
	copy(mac[:], raw)
	return mac, true
}
