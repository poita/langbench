// Package hexcodec encodes and decodes the lowercase hexadecimal byte strings
// used by the command language.
//
// Besides plain hex it implements the "argument" convention in which the empty
// byte string is written as the single character '-'.
package hexcodec

import "errors"

// ErrInvalid is returned for odd-length input or characters other than 0-9a-f.
var ErrInvalid = errors.New("hexcodec: invalid hex")

const digits = "0123456789abcdef"

var decTable [256]byte

func init() {
	for i := range decTable {
		decTable[i] = 0xff
	}
	for i := 0; i < 16; i++ {
		decTable[digits[i]] = byte(i)
	}
}

// Decode decodes src, which must be an even-length run of lowercase hex
// digits (possibly empty), into a newly allocated buffer.
func Decode(src []byte) ([]byte, error) {
	if len(src)%2 != 0 {
		return nil, ErrInvalid
	}
	out := make([]byte, len(src)/2)
	for i := range out {
		hi, lo := decTable[src[2*i]], decTable[src[2*i+1]]
		if hi|lo > 0x0f {
			return nil, ErrInvalid
		}
		out[i] = hi<<4 | lo
	}
	return out, nil
}

// DecodeArg decodes a command argument: either "-" (the empty byte string) or
// a non-empty hex string. An empty argument is invalid.
func DecodeArg(src []byte) ([]byte, error) {
	if len(src) == 1 && src[0] == '-' {
		return []byte{}, nil
	}
	if len(src) == 0 {
		return nil, ErrInvalid
	}
	return Decode(src)
}

// Append appends the lowercase hex encoding of src to dst.
func Append(dst, src []byte) []byte {
	for _, b := range src {
		dst = append(dst, digits[b>>4], digits[b&15])
	}
	return dst
}

// AppendArg appends the argument encoding of src: its hex encoding, or "-" if
// src is empty.
func AppendArg(dst, src []byte) []byte {
	if len(src) == 0 {
		return append(dst, '-')
	}
	return Append(dst, src)
}
