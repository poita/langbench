// Package b64 implements the Base64 dialect used by Standard Webhooks.
//
// Encoding comes in two flavours: standard (padded, "+/") and URL-safe
// (unpadded, "-_"). Decoding is a single lenient-but-strict routine that
// accepts either alphabet (never mixed), requires padding, when present, to be
// exactly what the encoder would emit, and ignores non-zero trailing bits.
package b64

import "errors"

const (
	stdAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

// ErrInvalid is returned by Decode for any malformed input.
var ErrInvalid = errors.New("b64: invalid base64")

// Per-byte decode tables: value is the 6-bit value or -1; class is 1 for the
// characters only in the standard alphabet ("+/"), 2 for those only in the
// URL-safe one ("-_") and 0 for those in both.
var (
	value [256]int8
	class [256]uint8
)

func init() {
	for i := range value {
		value[i] = -1
	}
	for i := 0; i < 64; i++ {
		value[stdAlphabet[i]] = int8(i)
		value[urlAlphabet[i]] = int8(i)
	}
	class['+'], class['/'] = 1, 1
	class['-'], class['_'] = 2, 2
}

func appendEncode(dst, src []byte, alphabet string, pad bool) []byte {
	i := 0
	for ; i+3 <= len(src); i += 3 {
		v := uint(src[i])<<16 | uint(src[i+1])<<8 | uint(src[i+2])
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63], alphabet[v>>6&63], alphabet[v&63])
	}
	switch len(src) - i {
	case 1:
		v := uint(src[i]) << 16
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63])
		if pad {
			dst = append(dst, '=', '=')
		}
	case 2:
		v := uint(src[i])<<16 | uint(src[i+1])<<8
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63], alphabet[v>>6&63])
		if pad {
			dst = append(dst, '=')
		}
	}
	return dst
}

// AppendEncode appends the padded standard Base64 encoding of src to dst.
func AppendEncode(dst, src []byte) []byte { return appendEncode(dst, src, stdAlphabet, true) }

// AppendEncodeURL appends the unpadded URL-safe Base64 encoding of src to dst.
func AppendEncodeURL(dst, src []byte) []byte { return appendEncode(dst, src, urlAlphabet, false) }

// Encode returns the padded standard Base64 encoding of src.
func Encode(src []byte) string {
	return string(AppendEncode(make([]byte, 0, (len(src)+2)/3*4), src))
}

// EncodeURL returns the unpadded URL-safe Base64 encoding of src.
func EncodeURL(src []byte) string {
	return string(AppendEncodeURL(make([]byte, 0, (len(src)+2)/3*4), src))
}

// AppendDecode decodes s and appends the bytes to dst. On error dst is
// returned unchanged along with ErrInvalid.
func AppendDecode(dst []byte, s string) ([]byte, error) {
	n := len(s)
	pad := 0
	for pad < n && s[n-1-pad] == '=' {
		pad++
	}
	if pad > 2 {
		return dst, ErrInvalid
	}
	body := s[:n-pad]
	var seen uint8
	for i := 0; i < len(body); i++ {
		c := body[i]
		if value[c] < 0 {
			return dst, ErrInvalid
		}
		seen |= class[c]
	}
	if seen == 3 { // both "+/" and "-_" present
		return dst, ErrInvalid
	}
	rem := len(body) % 4
	if rem == 1 {
		return dst, ErrInvalid
	}
	if pad > 0 {
		switch {
		case rem == 0, rem == 3 && pad != 1, rem == 2 && pad != 2:
			return dst, ErrInvalid
		}
	}
	var acc uint32
	nbits := 0
	for i := 0; i < len(body); i++ {
		acc = acc<<6 | uint32(value[body[i]])
		nbits += 6
		if nbits >= 8 {
			nbits -= 8
			dst = append(dst, byte(acc>>uint(nbits)))
			acc &= 1<<uint(nbits) - 1
		}
	}
	return dst, nil
}

// Decode decodes s, which may use either alphabet. It returns ErrInvalid if
// s is malformed. The empty string decodes to an empty slice.
func Decode(s string) ([]byte, error) {
	out, err := AppendDecode(make([]byte, 0, len(s)/4*3+3), s)
	if err != nil {
		return nil, err
	}
	return out, nil
}
