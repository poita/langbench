package vfs

const (
	fnvOffset uint64 = 0xcbf29ce484222325
	fnvPrime  uint64 = 0x100000001b3
)

// Hash64 returns the 64-bit FNV-1a hash of b.
func Hash64(b []byte) uint64 {
	h := fnvOffset
	for _, c := range b {
		h ^= uint64(c)
		h *= fnvPrime
	}
	return h
}

const hexDigits = "0123456789abcdef"

// HexHash renders h as exactly 16 lowercase hexadecimal digits.
func HexHash(h uint64) string {
	var buf [16]byte
	for i := 15; i >= 0; i-- {
		buf[i] = hexDigits[h&0xf]
		h >>= 4
	}
	return string(buf[:])
}

// ParseHexHash parses the output of HexHash. It accepts only exactly 16
// lowercase hexadecimal digits.
func ParseHexHash(s string) (uint64, bool) {
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
