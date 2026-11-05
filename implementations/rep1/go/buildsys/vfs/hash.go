package vfs

const (
	fnvOffset = 0xcbf29ce484222325
	fnvPrime  = 0x100000001b3
)

// Hash64 returns the 64-bit FNV-1a hash of b.
func Hash64(b []byte) uint64 {
	h := uint64(fnvOffset)
	for _, c := range b {
		h ^= uint64(c)
		h *= fnvPrime
	}
	return h
}

const hexDigits = "0123456789abcdef"

// HashHex formats h as exactly 16 lowercase hexadecimal digits.
func HashHex(h uint64) string {
	var buf [16]byte
	AppendHashHex(buf[:0], h)
	return string(buf[:])
}

// AppendHashHex appends the 16-digit hexadecimal form of h to dst.
func AppendHashHex(dst []byte, h uint64) []byte {
	for shift := 60; shift >= 0; shift -= 4 {
		dst = append(dst, hexDigits[(h>>uint(shift))&0xf])
	}
	return dst
}

// ParseHashHex parses exactly 16 lowercase hex digits.
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
