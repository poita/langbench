package protocol

import (
	"errors"
	"strings"

	"example.com/webhooks"
	"example.com/webhooks/simulate"
)

var errBadField = errors.New("bad field")

// parseHex decodes a <hex> field: "-" for no bytes, otherwise an even number
// of lowercase hex digits.
func parseHex(s string) ([]byte, error) {
	if s == "-" {
		return []byte{}, nil
	}
	if len(s) == 0 || len(s)%2 != 0 {
		return nil, errBadField
	}
	out := make([]byte, len(s)/2)
	for i := range out {
		hi, ok1 := hexVal(s[2*i])
		lo, ok2 := hexVal(s[2*i+1])
		if !ok1 || !ok2 {
			return nil, errBadField
		}
		out[i] = hi<<4 | lo
	}
	return out, nil
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	}
	return 0, false
}

// formatHex is the inverse of parseHex.
func formatHex(b []byte) string {
	if len(b) == 0 {
		return "-"
	}
	const digits = "0123456789abcdef"
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i] = digits[c>>4]
		out[2*i+1] = digits[c&15]
	}
	return string(out)
}

// printable reports whether s has between 1 and max characters, all in
// 0x21..0x7e.
func printable(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

// parseID parses an <id>: 1..256 printable characters.
func parseID(s string) (string, error) {
	if !printable(s, 256) {
		return "", errBadField
	}
	return s, nil
}

func parseSecret(s string) ([]byte, error) {
	if !printable(s, 512) || strings.IndexByte(s, ',') >= 0 {
		return nil, errBadField
	}
	return webhooks.ParseSecret(s)
}

// parseSecrets parses a <secrets> field: 1..16 comma-separated secrets.
func parseSecrets(s string) ([][]byte, error) {
	parts := strings.Split(s, ",")
	if len(parts) > 16 {
		return nil, errBadField
	}
	keys := make([][]byte, len(parts))
	for i, p := range parts {
		k, err := parseSecret(p)
		if err != nil {
			return nil, errBadField
		}
		keys[i] = k
	}
	return keys, nil
}

// isName reports whether s is 1..64 characters from [A-Za-z0-9_.-].
func isName(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
			c == '_', c == '.', c == '-':
		default:
			return false
		}
	}
	return true
}

// parseFilter parses an endpoint filter: "*" (nil result) or 1..16 types.
func parseFilter(s string) ([]string, error) {
	if s == "*" {
		return nil, nil
	}
	parts := strings.Split(s, ",")
	if len(parts) > 16 {
		return nil, errBadField
	}
	for _, p := range parts {
		if !isName(p) {
			return nil, errBadField
		}
	}
	return parts, nil
}

// parseScript parses 1..64 comma-separated responses.
func parseScript(s string) ([]simulate.Response, error) {
	parts := strings.Split(s, ",")
	if len(parts) > 64 {
		return nil, errBadField
	}
	out := make([]simulate.Response, len(parts))
	for i, p := range parts {
		if p == "timeout" {
			out[i] = simulate.Response{Timeout: true}
			continue
		}
		if len(p) != 3 {
			return nil, errBadField
		}
		code := 0
		for j := 0; j < 3; j++ {
			if p[j] < '0' || p[j] > '9' {
				return nil, errBadField
			}
			code = code*10 + int(p[j]-'0')
		}
		if code < 100 || code > 599 {
			return nil, errBadField
		}
		out[i] = simulate.Response{Code: code}
	}
	return out, nil
}
