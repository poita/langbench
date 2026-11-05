package wire

const hexDigits = "0123456789abcdef"

// hexVal maps an ASCII byte to its value as a lowercase hex digit, or 0xff.
var hexVal = func() (t [256]byte) {
	for i := range t {
		t[i] = 0xff
	}
	for i := 0; i < 16; i++ {
		t[hexDigits[i]] = byte(i)
	}
	return
}()

// HexValue returns the value of the lowercase hex digit c, and whether c is
// one. Uppercase digits are rejected.
func HexValue(c byte) (byte, bool) {
	v := hexVal[c]
	return v, v != 0xff
}

// AppendHex appends the lowercase hex encoding of src to dst.
func AppendHex(dst, src []byte) []byte {
	for _, c := range src {
		dst = append(dst, hexDigits[c>>4], hexDigits[c&15])
	}
	return dst
}

// AppendUnhex appends the bytes denoted by the hex string src to dst. It
// reports false (and returns dst unchanged) if src has odd length or holds
// anything other than lowercase hex digits.
func AppendUnhex(dst, src []byte) ([]byte, bool) {
	if len(src)%2 != 0 {
		return dst, false
	}
	n := len(dst)
	for i := 0; i < len(src); i += 2 {
		hi, lo := hexVal[src[i]], hexVal[src[i+1]]
		if (hi | lo) > 15 {
			return dst[:n], false
		}
		dst = append(dst, hi<<4|lo)
	}
	return dst, true
}
