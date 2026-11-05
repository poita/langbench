package signature

import (
	"webhooks/base64"
	"webhooks/hmac"
)

// AppendSignature appends the single signature "v1,<base64 mac>" computed
// with s over id, ts and body to dst. ts is the timestamp text exactly as it
// appears on the wire.
func AppendSignature(dst []byte, s *Secret, id, ts, body []byte) []byte {
	var mac [hmac.Size]byte
	s.MAC(&mac, id, ts, body)
	dst = append(dst, 'v', '1', ',')
	return base64.AppendStd(dst, mac[:])
}

// AppendHeader appends the webhook-signature header value for secrets: one
// signature per secret, in order, joined by single spaces.
func AppendHeader(dst []byte, secrets []Secret, id, ts, body []byte) []byte {
	for i := range secrets {
		if i > 0 {
			dst = append(dst, ' ')
		}
		dst = AppendSignature(dst, &secrets[i], id, ts, body)
	}
	return dst
}

// Sign returns the webhook-signature header value for secrets.
func Sign(secrets []Secret, id, ts, body []byte) []byte {
	return AppendHeader(make([]byte, 0, len(secrets)*48), secrets, id, ts, body)
}
