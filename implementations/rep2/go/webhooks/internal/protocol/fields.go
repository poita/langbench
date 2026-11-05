package protocol

import (
	"example.com/webhooks/hmac"
	"example.com/webhooks/signature"
)

// splitFields splits line on single spaces into dst (reused), as views into
// line. ok is false when any field is empty.
func splitFields(line []byte, dst [][]byte) (fields [][]byte, ok bool) {
	dst = dst[:0]
	ok = true
	start := 0
	for i := 0; i <= len(line); i++ {
		if i == len(line) || line[i] == ' ' {
			if i == start {
				ok = false
			}
			dst = append(dst, line[start:i])
			start = i + 1
		}
	}
	return dst, ok
}

func isBlank(line []byte) bool {
	for _, c := range line {
		if c != ' ' {
			return false
		}
	}
	return true
}

// hexVal maps a lowercase hex digit to its value, or 0xff.
var hexVal [256]uint8

func init() {
	for i := range hexVal {
		hexVal[i] = 0xff
	}
	for i := 0; i < 10; i++ {
		hexVal['0'+i] = uint8(i)
	}
	for i := 0; i < 6; i++ {
		hexVal['a'+i] = uint8(10 + i)
	}
}

// decodeHex decodes a <hex> field: "-" (empty) or an even run of lowercase
// hex digits.
func decodeHex(f []byte) ([]byte, bool) {
	if len(f) == 1 && f[0] == '-' {
		return []byte{}, true
	}
	if len(f) == 0 || len(f)%2 != 0 {
		return nil, false
	}
	out := make([]byte, len(f)/2)
	for i := range out {
		hi, lo := hexVal[f[2*i]], hexVal[f[2*i+1]]
		if hi|lo == 0xff || hi > 15 || lo > 15 {
			return nil, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

const hexDigits = "0123456789abcdef"

// appendHex appends the lowercase hex of b, or "-" when b is empty.
func appendHex(dst, b []byte) []byte {
	if len(b) == 0 {
		return append(dst, '-')
	}
	for _, c := range b {
		dst = append(dst, hexDigits[c>>4], hexDigits[c&15])
	}
	return dst
}

func isPrintable(f []byte) bool {
	for _, c := range f {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}

// parseID validates an <id>: 1..256 printable ASCII characters.
func parseID(f []byte) (string, bool) {
	if len(f) < 1 || len(f) > 256 || !isPrintable(f) {
		return "", false
	}
	return string(f), true
}

// parseName validates an ep-id, ev-id or type: 1..64 of [A-Za-z0-9_.-].
func parseName(f []byte) (string, bool) {
	if len(f) < 1 || len(f) > 64 {
		return "", false
	}
	for _, c := range f {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
			c == '_', c == '.', c == '-':
		default:
			return "", false
		}
	}
	return string(f), true
}

// parseSecret validates a <secret> field and derives its key.
func parseSecret(f []byte) (*hmac.Key, bool) {
	if len(f) < 1 || len(f) > 512 {
		return nil, false
	}
	for _, c := range f {
		if c < 0x21 || c > 0x7e || c == ',' {
			return nil, false
		}
	}
	k, err := signature.ParseSecret(string(f))
	return k, err == nil
}

// parseSecrets validates a <secrets> field: 1..16 comma-joined secrets.
func parseSecrets(f []byte) ([]*hmac.Key, bool) {
	var keys []*hmac.Key
	start := 0
	for i := 0; i <= len(f); i++ {
		if i == len(f) || f[i] == ',' {
			if len(keys) == 16 {
				return nil, false
			}
			k, ok := parseSecret(f[start:i])
			if !ok {
				return nil, false
			}
			keys = append(keys, k)
			start = i + 1
		}
	}
	return keys, true
}
