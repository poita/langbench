package vfs

import "strconv"

const (
	fnvOffset uint64 = 0xcbf29ce484222325
	fnvPrime  uint64 = 0x100000001b3
)

// Hash returns the 64-bit FNV-1a hash of data.
func Hash(data []byte) uint64 {
	h := fnvOffset
	for _, b := range data {
		h ^= uint64(b)
		h *= fnvPrime
	}
	return h
}

// HashHex formats a hash as exactly 16 lowercase hexadecimal digits.
func HashHex(h uint64) string {
	s := strconv.FormatUint(h, 16)
	if len(s) < 16 {
		s = "0000000000000000"[:16-len(s)] + s
	}
	return s
}

// ParseHashHex parses exactly 16 lowercase hexadecimal digits.
func ParseHashHex(s string) (uint64, bool) {
	if len(s) != 16 {
		return 0, false
	}
	var h uint64
	for i := 0; i < 16; i++ {
		c := s[i]
		var d byte
		switch {
		case c >= '0' && c <= '9':
			d = c - '0'
		case c >= 'a' && c <= 'f':
			d = c - 'a' + 10
		default:
			return 0, false
		}
		h = h<<4 | uint64(d)
	}
	return h, true
}
