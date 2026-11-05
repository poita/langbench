package jsoncanon

import "encoding/binary"

// validUTF8 reports whether b is well-formed UTF-8 per RFC 3629: no overlong
// forms, no surrogates (U+D800–U+DFFF), nothing above U+10FFFF and no
// truncated sequences. It returns the offset of the first bad byte otherwise.
func validUTF8(b []byte) (ok bool, bad int) {
	i, n := 0, len(b)
	for i < n {
		// Skip ASCII eight bytes at a time.
		for i+8 <= n && binary.LittleEndian.Uint64(b[i:])&0x8080808080808080 == 0 {
			i += 8
		}
		if i >= n {
			break
		}
		c := b[i]
		if c < 0x80 {
			i++
			continue
		}
		switch {
		case c >= 0xC2 && c <= 0xDF:
			if i+1 >= n || !isCont(b[i+1]) {
				return false, i
			}
			i += 2
		case c >= 0xE0 && c <= 0xEF:
			if i+2 >= n || !isCont(b[i+2]) {
				return false, i
			}
			lo, hi := byte(0x80), byte(0xBF)
			switch c {
			case 0xE0:
				lo = 0xA0 // overlong
			case 0xED:
				hi = 0x9F // surrogates
			}
			if b[i+1] < lo || b[i+1] > hi {
				return false, i
			}
			i += 3
		case c >= 0xF0 && c <= 0xF4:
			if i+3 >= n || !isCont(b[i+2]) || !isCont(b[i+3]) {
				return false, i
			}
			lo, hi := byte(0x80), byte(0xBF)
			switch c {
			case 0xF0:
				lo = 0x90 // overlong
			case 0xF4:
				hi = 0x8F // above U+10FFFF
			}
			if b[i+1] < lo || b[i+1] > hi {
				return false, i
			}
			i += 4
		default:
			return false, i
		}
	}
	return true, 0
}

func isCont(c byte) bool { return c&0xC0 == 0x80 }
