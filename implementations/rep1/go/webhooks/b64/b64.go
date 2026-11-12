// Package b64 implements standard and URL-safe Base64 from scratch.
//
// Encoding follows RFC 4648: the standard alphabet is padded with '=', the
// URL-safe alphabet is not. Decoding is deliberately lenient about the
// alphabet (either one is accepted, but not both in the same string) and
// strict about padding, which must be exactly what the encoder would emit.
// Non-zero trailing bits in the last character are ignored.
package b64

import "errors"

const (
	stdAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

// ErrInvalid is returned by Decode for any malformed input.
var ErrInvalid = errors.New("b64: invalid base64")

// Character classes used while decoding.
const (
	clsBad  = 0xff
	clsPlus = 0xfe // '+' or '/': standard alphabet only
	clsDash = 0xfd // '-' or '_': URL-safe alphabet only
)

// decodeTab maps a byte to its 6-bit value, or clsBad.
var decodeTab = func() (t [256]byte) {
	for i := range t {
		t[i] = clsBad
	}
	for i := 0; i < 64; i++ {
		t[stdAlphabet[i]] = byte(i)
		t[urlAlphabet[i]] = byte(i)
	}
	return
}()

func encode(src []byte, alphabet string, pad bool) string {
	out := make([]byte, 0, (len(src)+2)/3*4)
	i := 0
	for ; i+3 <= len(src); i += 3 {
		v := uint32(src[i])<<16 | uint32(src[i+1])<<8 | uint32(src[i+2])
		out = append(out, alphabet[v>>18&63], alphabet[v>>12&63], alphabet[v>>6&63], alphabet[v&63])
	}
	switch len(src) - i {
	case 1:
		v := uint32(src[i]) << 16
		out = append(out, alphabet[v>>18&63], alphabet[v>>12&63])
		if pad {
			out = append(out, '=', '=')
		}
	case 2:
		v := uint32(src[i])<<16 | uint32(src[i+1])<<8
		out = append(out, alphabet[v>>18&63], alphabet[v>>12&63], alphabet[v>>6&63])
		if pad {
			out = append(out, '=')
		}
	}
	return string(out)
}

// EncodeStd returns the padded standard Base64 encoding of src.
func EncodeStd(src []byte) string { return encode(src, stdAlphabet, true) }

// EncodeURL returns the unpadded URL-safe Base64 encoding of src.
func EncodeURL(src []byte) string { return encode(src, urlAlphabet, false) }

// Decode decodes s, which may use either alphabet (but not both) and may
// carry the canonical amount of '=' padding. The empty string decodes to an
// empty, non-nil slice. Any violation yields ErrInvalid.
func Decode(s string) ([]byte, error) {
	end := len(s)
	for end > 0 && s[end-1] == '=' {
		end--
	}
	pad := len(s) - end
	body := s[:end]
	n := len(body)

	var sawPlus, sawDash bool
	for i := 0; i < n; i++ {
		switch c := body[i]; c {
		case '+', '/':
			sawPlus = true
		case '-', '_':
			sawDash = true
		default:
			if decodeTab[c] == clsBad {
				return nil, ErrInvalid
			}
		}
	}
	if sawPlus && sawDash {
		return nil, ErrInvalid
	}
	rem := n % 4
	if rem == 1 {
		return nil, ErrInvalid
	}
	if pad > 0 {
		want := 0
		switch rem {
		case 3:
			want = 1
		case 2:
			want = 2
		}
		if pad != want {
			return nil, ErrInvalid
		}
	}

	out := make([]byte, 0, n*6/8)
	var acc uint32
	bits := 0
	for i := 0; i < n; i++ {
		acc = acc<<6 | uint32(sextet(body[i]))
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(acc>>uint(bits)))
			acc &= 1<<uint(bits) - 1
		}
	}
	return out, nil
}

func sextet(c byte) byte {
	switch c {
	case '+', '-':
		return 62
	case '/', '_':
		return 63
	}
	return decodeTab[c]
}
