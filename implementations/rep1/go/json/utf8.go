package jsoncanon

// ValidUTF8 reports whether data is well-formed UTF-8 as defined by RFC 3629:
// no overlong forms, no encoded surrogates, nothing above U+10FFFF and no
// truncated sequences.
func ValidUTF8(data []byte) bool {
	return invalidUTF8Offset(data) < 0
}

// invalidUTF8Offset returns the offset of the first byte that starts an
// invalid sequence, or -1 if data is valid.
func invalidUTF8Offset(data []byte) int {
	n := len(data)
	i := 0
	for i < n {
		c := data[i]
		if c < 0x80 {
			i++
			continue
		}
		switch {
		case c < 0xC2: // continuation byte, or overlong 2-byte lead (C0, C1)
			return i
		case c < 0xE0:
			if i+1 >= n || data[i+1]&0xC0 != 0x80 {
				return i
			}
			i += 2
		case c < 0xF0:
			if i+2 >= n {
				return i
			}
			c1, c2 := data[i+1], data[i+2]
			if c1&0xC0 != 0x80 || c2&0xC0 != 0x80 {
				return i
			}
			if c == 0xE0 && c1 < 0xA0 { // overlong
				return i
			}
			if c == 0xED && c1 > 0x9F { // surrogates
				return i
			}
			i += 3
		case c < 0xF5:
			if i+3 >= n {
				return i
			}
			c1, c2, c3 := data[i+1], data[i+2], data[i+3]
			if c1&0xC0 != 0x80 || c2&0xC0 != 0x80 || c3&0xC0 != 0x80 {
				return i
			}
			if c == 0xF0 && c1 < 0x90 { // overlong
				return i
			}
			if c == 0xF4 && c1 > 0x8F { // above U+10FFFF
				return i
			}
			i += 4
		default:
			return i
		}
	}
	return -1
}
