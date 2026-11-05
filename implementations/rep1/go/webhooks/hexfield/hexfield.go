// Package hexfield encodes and decodes the hex "fields" of the command
// protocol: lowercase hex digits with no separators, where the empty byte
// string is written as the single character "-".
package hexfield

import "errors"

// ErrInvalid is returned by Decode for malformed fields.
var ErrInvalid = errors.New("hexfield: invalid hex field")

const digits = "0123456789abcdef"

var table [256]int8

func init() {
	for i := range table {
		table[i] = -1
	}
	for i := 0; i < 16; i++ {
		table[digits[i]] = int8(i)
	}
}

// Decode decodes a field: "-" is the empty string, otherwise s must be a
// non-empty even-length run of lowercase hex digits. The result is allocated
// once at its final size.
func Decode(s []byte) ([]byte, error) {
	if len(s) == 1 && s[0] == '-' {
		return []byte{}, nil
	}
	if len(s) == 0 || len(s)%2 != 0 {
		return nil, ErrInvalid
	}
	out := make([]byte, len(s)/2)
	for i := range out {
		hi, lo := table[s[2*i]], table[s[2*i+1]]
		if hi < 0 || lo < 0 {
			return nil, ErrInvalid
		}
		out[i] = byte(hi)<<4 | byte(lo)
	}
	return out, nil
}

// Valid reports whether s is a well-formed field.
func Valid(s []byte) bool {
	if len(s) == 1 && s[0] == '-' {
		return true
	}
	if len(s) == 0 || len(s)%2 != 0 {
		return false
	}
	for _, c := range s {
		if table[c] < 0 {
			return false
		}
	}
	return true
}

// AppendEncode appends the field encoding of b to dst: lowercase hex, or "-"
// when b is empty.
func AppendEncode(dst, b []byte) []byte {
	if len(b) == 0 {
		return append(dst, '-')
	}
	for _, c := range b {
		dst = append(dst, digits[c>>4], digits[c&15])
	}
	return dst
}

// Encode returns the field encoding of b.
func Encode(b []byte) string {
	return string(AppendEncode(make([]byte, 0, 2*len(b)+1), b))
}
