// Package transfer implements Content-Transfer-Encoding decoding: quoted-printable
// and base64 are decoded by hand; every other encoding is the identity.
package transfer

// Decode returns the decoded bytes of body for the (lower-case) encoding
// token. 7bit, 8bit, binary and unrecognised encodings return body unchanged.
// The result may alias body.
func Decode(body []byte, encoding string) []byte {
	switch encoding {
	case "quoted-printable":
		return DecodeQuotedPrintable(body)
	case "base64":
		return DecodeBase64(body)
	}
	return body
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// HexValue returns the value of the hexadecimal digit c, or -1.
func HexValue(c byte) int { return hexVal(c) }

// DecodeQuotedPrintable decodes quoted-printable text whose lines end in LF.
//
// At "=": a following LF is a soft line break (both dropped); two following
// hex digits give one byte; a "=" that is the last byte is dropped; any other
// "=" is kept literally. All other bytes are copied unchanged.
func DecodeQuotedPrintable(b []byte) []byte {
	out := make([]byte, 0, len(b))
	n := len(b)
	for i := 0; i < n; i++ {
		c := b[i]
		if c != '=' {
			out = append(out, c)
			continue
		}
		switch {
		case i+1 < n && b[i+1] == '\n':
			i++
		case i+2 < n && hexVal(b[i+1]) >= 0 && hexVal(b[i+2]) >= 0:
			out = append(out, byte(hexVal(b[i+1])<<4|hexVal(b[i+2])))
			i += 2
		case i+1 == n:
			// trailing "=": dropped
		default:
			out = append(out, '=')
		}
	}
	return out
}

var b64 = func() (t [256]int8) {
	for i := range t {
		t[i] = -1
	}
	const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(alpha); i++ {
		t[alpha[i]] = int8(i)
	}
	return
}()

// DecodeBase64 decodes base64 leniently: bytes outside the alphabet
// (including "=") are discarded, complete groups of four characters give three
// bytes, and a final group of two or three characters gives one or two bytes.
// A single leftover character is discarded.
func DecodeBase64(b []byte) []byte {
	out := make([]byte, 0, len(b)/4*3+3)
	var acc uint32
	k := 0
	for _, c := range b {
		v := b64[c]
		if v < 0 {
			continue
		}
		acc = acc<<6 | uint32(v)
		k++
		if k == 4 {
			out = append(out, byte(acc>>16), byte(acc>>8), byte(acc))
			acc, k = 0, 0
		}
	}
	switch k {
	case 2:
		out = append(out, byte(acc>>4))
	case 3:
		out = append(out, byte(acc>>10), byte(acc>>2))
	}
	return out
}
