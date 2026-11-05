package signature

import "example.com/webhooks/b64"

// Version is the only signature version produced and accepted.
const Version = "v1"

// AppendSign appends the webhook-signature header value for the message to
// dst: one "v1,<base64>" per secret, in order, separated by single spaces.
// ts is the timestamp text exactly as it appears in the webhook-timestamp
// header.
func AppendSign(dst []byte, secrets []*Secret, id, ts string, body []byte) []byte {
	for i, s := range secrets {
		if i > 0 {
			dst = append(dst, ' ')
		}
		sum := s.mac(id, ts, body)
		dst = append(dst, Version...)
		dst = append(dst, ',')
		dst = b64.AppendEncode(dst, sum[:])
	}
	return dst
}

// Sign returns the webhook-signature header value for the message; see
// AppendSign.
func Sign(secrets []*Secret, id, ts string, body []byte) string {
	return string(AppendSign(make([]byte, 0, len(secrets)*47), secrets, id, ts, body))
}
