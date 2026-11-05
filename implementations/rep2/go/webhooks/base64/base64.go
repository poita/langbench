// Package base64 is a from-scratch Base64 codec with the two alphabets used
// by the webhook scheme: padded standard (RFC 4648 §4) for encoding
// signatures and a lenient decoder that accepts either alphabet.
package base64

import "errors"

const (
	stdAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

// ErrInvalid is returned by the decoding functions for malformed input.
var ErrInvalid = errors.New("base64: invalid input")

// Character classes in the decode table.
const (
	clsInvalid  = 0
	clsCommon   = 1 // A-Z a-z 0-9, in both alphabets
	clsStandard = 2 // + /
	clsURL      = 3 // - _
)

var (
	decVal [256]uint8
	decCls [256]uint8
)

func init() {
	for i := 0; i < 64; i++ {
		c := stdAlphabet[i]
		decVal[c] = uint8(i)
		decCls[c] = clsCommon
		if i >= 62 {
			decCls[c] = clsStandard
			u := urlAlphabet[i]
			decVal[u] = uint8(i)
			decCls[u] = clsURL
		}
	}
}

func appendEncoded(dst, src []byte, alphabet string, pad bool) []byte {
	i := 0
	for ; i+3 <= len(src); i += 3 {
		v := uint(src[i])<<16 | uint(src[i+1])<<8 | uint(src[i+2])
		dst = append(dst, alphabet[v>>18&63], alphabet[v>>12&63], alphabet[v>>6&63], alphabet[v&63])
	}
	switch len(src) - i {
	case 1:
		v := uint(src[i]) << 16
		dst = append(dst, alphabet[v>>18&63], alphabet[v>>12&63])
		if pad {
			dst = append(dst, '=', '=')
		}
	case 2:
		v := uint(src[i])<<16 | uint(src[i+1])<<8
		dst = append(dst, alphabet[v>>18&63], alphabet[v>>12&63], alphabet[v>>6&63])
		if pad {
			dst = append(dst, '=')
		}
	}
	return dst
}

// AppendStandard appends the padded standard-alphabet encoding of src to dst.
func AppendStandard(dst, src []byte) []byte { return appendEncoded(dst, src, stdAlphabet, true) }

// AppendURL appends the unpadded URL-safe encoding of src to dst.
func AppendURL(dst, src []byte) []byte { return appendEncoded(dst, src, urlAlphabet, false) }

// EncodeStandard returns the padded standard-alphabet encoding of src.
func EncodeStandard(src []byte) string {
	return string(AppendStandard(make([]byte, 0, (len(src)+2)/3*4), src))
}

// EncodeURL returns the unpadded URL-safe encoding of src.
func EncodeURL(src []byte) string {
	return string(AppendURL(make([]byte, 0, (len(src)*4+2)/3), src))
}

// AppendDecode decodes src and appends the bytes to dst. On error it returns
// dst unchanged and ErrInvalid.
//
// Either alphabet is accepted but not a mixture of the two. Padding is
// optional, but if present it must be exactly what the encoder would emit.
// Left-over low bits in the final character are discarded without checking.
// The empty string decodes to zero bytes.
func AppendDecode(dst, src []byte) ([]byte, error) {
	body := src
	for len(body) > 0 && body[len(body)-1] == '=' {
		body = body[:len(body)-1]
	}
	p := len(src) - len(body)
	n := len(body)
	if p > 2 || n%4 == 1 {
		return dst, ErrInvalid
	}
	if p > 0 {
		switch n % 4 {
		case 0:
			return dst, ErrInvalid
		case 2:
			if p != 2 {
				return dst, ErrInvalid
			}
		case 3:
			if p != 1 {
				return dst, ErrInvalid
			}
		}
	}
	var sawStd, sawURL bool
	for _, c := range body {
		switch decCls[c] {
		case clsInvalid:
			return dst, ErrInvalid
		case clsStandard:
			sawStd = true
		case clsURL:
			sawURL = true
		}
	}
	if sawStd && sawURL {
		return dst, ErrInvalid
	}
	outLen := n * 6 / 8
	var acc uint32
	var bits uint
	emitted := 0
	for _, c := range body {
		acc = acc<<6 | uint32(decVal[c])
		bits += 6
		if bits >= 8 {
			bits -= 8
			if emitted < outLen {
				dst = append(dst, byte(acc>>bits))
				emitted++
			}
			acc &= 1<<bits - 1
		}
	}
	return dst, nil
}

// Decode decodes src; see AppendDecode for the accepted syntax.
func Decode(src []byte) ([]byte, error) {
	out, err := AppendDecode(make([]byte, 0, len(src)*3/4), src)
	if err != nil {
		return nil, err
	}
	return out, nil
}
