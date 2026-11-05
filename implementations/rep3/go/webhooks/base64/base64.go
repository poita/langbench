// Package base64 implements the Base64 variants used by Standard Webhooks.
//
// Encoding produces either the padded standard alphabet or the unpadded
// URL-safe alphabet. Decoding is a single lenient-alphabet routine: it accepts
// either alphabet (but never a mix), optional canonical padding, and ignores
// the unused low bits of the last character.
package base64

import (
	"errors"
	"slices"
)

const (
	stdAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

// ErrInvalid is returned by Decode for any input that is not valid Base64.
var ErrInvalid = errors.New("base64: invalid input")

// Decode table entries: the low 6 bits hold the value; the flags mark
// characters that only exist in one alphabet.
const (
	invalid  = 0xff
	flagStd  = 0x40 // '+' or '/'
	flagURL  = 0x80 // '-' or '_'
	valueMsk = 0x3f
)

var decTable [256]byte

func init() {
	for i := range decTable {
		decTable[i] = invalid
	}
	for i := 0; i < 64; i++ {
		decTable[stdAlphabet[i]] = byte(i)
		decTable[urlAlphabet[i]] = byte(i)
	}
	decTable['+'] |= flagStd
	decTable['/'] |= flagStd
	decTable['-'] |= flagURL
	decTable['_'] |= flagURL
}

func appendEncoded(dst, src []byte, alphabet string, pad bool) []byte {
	i := 0
	for ; i+3 <= len(src); i += 3 {
		v := uint32(src[i])<<16 | uint32(src[i+1])<<8 | uint32(src[i+2])
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63], alphabet[v>>6&63], alphabet[v&63])
	}
	switch len(src) - i {
	case 1:
		v := uint32(src[i]) << 16
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63])
		if pad {
			dst = append(dst, '=', '=')
		}
	case 2:
		v := uint32(src[i])<<16 | uint32(src[i+1])<<8
		dst = append(dst, alphabet[v>>18], alphabet[v>>12&63], alphabet[v>>6&63])
		if pad {
			dst = append(dst, '=')
		}
	}
	return dst
}

// AppendStd appends the padded standard Base64 encoding of src to dst.
func AppendStd(dst, src []byte) []byte { return appendEncoded(dst, src, stdAlphabet, true) }

// AppendURL appends the unpadded URL-safe Base64 encoding of src to dst.
func AppendURL(dst, src []byte) []byte { return appendEncoded(dst, src, urlAlphabet, false) }

// EncodeStd returns the padded standard Base64 encoding of src.
func EncodeStd(src []byte) []byte {
	return AppendStd(make([]byte, 0, (len(src)+2)/3*4), src)
}

// EncodeURL returns the unpadded URL-safe Base64 encoding of src.
func EncodeURL(src []byte) []byte {
	return AppendURL(make([]byte, 0, (len(src)*4+2)/3), src)
}

// Decode validates src according to the rules of the specification and
// appends the decoded bytes to dst. On error it returns dst unchanged and
// ErrInvalid.
func Decode(dst, src []byte) ([]byte, error) {
	body := src
	p := 0
	for len(body) > 0 && body[len(body)-1] == '=' {
		body = body[:len(body)-1]
		p++
	}
	n := len(body)
	if n%4 == 1 || p > 2 {
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
	out := slices.Grow(dst, n*6/8)
	var acc uint32
	var bits uint
	var flags byte
	for _, c := range body {
		v := decTable[c]
		if v == invalid {
			return dst, ErrInvalid
		}
		flags |= v & (flagStd | flagURL)
		acc = acc<<6 | uint32(v&valueMsk)
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(acc>>bits))
		}
	}
	if flags == flagStd|flagURL {
		return dst, ErrInvalid
	}
	return out, nil
}
