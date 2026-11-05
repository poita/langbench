// Package transfer decodes Content-Transfer-Encoding payloads. Base64 and
// quoted-printable are implemented here by hand and are deliberately
// forgiving: malformed input never causes an error.
package transfer

import "mimedump/internal/scan"

// Decode implements decode_body. encoding must already be stripped and
// lower-cased. Identity encodings (7bit, 8bit, binary, unknown) return body
// itself without copying.
func Decode(body []byte, encoding string) []byte {
	switch encoding {
	case "quoted-printable":
		return QuotedPrintable(body)
	case "base64":
		return Base64(body)
	}
	return body
}

// sextet maps a byte to its base64 value, or 0xFF if it is not in the
// alphabet.
var sextet [256]byte

func init() {
	for i := range sextet {
		sextet[i] = 0xFF
	}
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(alphabet); i++ {
		sextet[alphabet[i]] = byte(i)
	}
}

// Base64 decodes src, skipping every byte outside the base64 alphabet ('='
// included). Each complete group of four characters gives three bytes; a
// trailing group of two or three characters gives one or two bytes; a single
// trailing character is dropped.
func Base64[S ~string | ~[]byte](src S) []byte {
	out := make([]byte, 0, len(src)*3/4+3)
	var acc uint32
	n := 0
	for i := 0; i < len(src); i++ {
		v := sextet[src[i]]
		if v == 0xFF {
			continue
		}
		acc = acc<<6 | uint32(v)
		n++
		if n == 4 {
			out = append(out, byte(acc>>16), byte(acc>>8), byte(acc))
			acc, n = 0, 0
		}
	}
	switch n {
	case 2:
		out = append(out, byte(acc>>4))
	case 3:
		out = append(out, byte(acc>>10), byte(acc>>2))
	}
	return out
}

// QuotedPrintable decodes src (LF line endings). "=" followed by LF is a soft
// line break, "=" followed by two hex digits is that byte, a final "=" is
// dropped, and any other "=" is literal. Everything else is copied unchanged.
func QuotedPrintable(src []byte) []byte {
	out := make([]byte, 0, len(src))
	for i := 0; i < len(src); {
		start := i
		for i < len(src) && src[i] != '=' {
			i++
		}
		out = append(out, src[start:i]...)
		if i >= len(src) {
			break
		}
		// src[i] == '='
		switch {
		case i+1 < len(src) && src[i+1] == '\n':
			i += 2
		case i+2 < len(src) && scan.HexVal(src[i+1]) >= 0 && scan.HexVal(src[i+2]) >= 0:
			out = append(out, byte(scan.HexVal(src[i+1])<<4|scan.HexVal(src[i+2])))
			i += 3
		case i+1 == len(src):
			i++
		default:
			out = append(out, '=')
			i++
		}
	}
	return out
}
