package value

import (
	"errors"
	"unicode/utf8"
)

var errBadEscape = errors.New("invalid escape sequence in string")

// ScanString finds the end of the JSON string literal that starts with the
// opening quote at s[start]. It returns the index just past the closing quote
// and whether the literal contains backslash escapes. Control characters
// below U+0020 are rejected.
func ScanString(s string, start int) (end int, escaped bool, err error) {
	for i := start + 1; i < len(s); i++ {
		switch c := s[i]; {
		case c == '"':
			return i + 1, escaped, nil
		case c == '\\':
			escaped = true
			i++
		case c < 0x20:
			return 0, false, errors.New("control character in string")
		}
	}
	return 0, false, errors.New("unterminated string")
}

// Unquote decodes the body of a JSON string literal (the text between the
// quotes). A surrogate pair of \u escapes yields one code point; an unpaired
// surrogate yields U+FFFD.
func Unquote(body string) (string, error) {
	buf := make([]byte, 0, len(body))
	for i := 0; i < len(body); i++ {
		c := body[i]
		if c != '\\' {
			buf = append(buf, c)
			continue
		}
		i++
		if i >= len(body) {
			return "", errBadEscape
		}
		switch body[i] {
		case '"', '\\', '/':
			buf = append(buf, body[i])
		case 'b':
			buf = append(buf, '\b')
		case 'f':
			buf = append(buf, '\f')
		case 'n':
			buf = append(buf, '\n')
		case 'r':
			buf = append(buf, '\r')
		case 't':
			buf = append(buf, '\t')
		case 'u':
			r, ok := hex4(body, i+1)
			if !ok {
				return "", errBadEscape
			}
			i += 4
			if r >= 0xD800 && r < 0xDC00 {
				if i+6 < len(body) && body[i+1] == '\\' && body[i+2] == 'u' {
					if lo, ok := hex4(body, i+3); ok && lo >= 0xDC00 && lo < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
						i += 6
					} else {
						r = utf8.RuneError
					}
				} else {
					r = utf8.RuneError
				}
			} else if r >= 0xDC00 && r < 0xE000 {
				r = utf8.RuneError
			}
			buf = appendRune(buf, r)
		default:
			return "", errBadEscape
		}
	}
	return string(buf), nil
}

func hex4(s string, i int) (rune, bool) {
	if i+4 > len(s) {
		return 0, false
	}
	var r rune
	for _, c := range []byte(s[i : i+4]) {
		switch {
		case c >= '0' && c <= '9':
			c -= '0'
		case c >= 'a' && c <= 'f':
			c = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			c = c - 'A' + 10
		default:
			return 0, false
		}
		r = r<<4 | rune(c)
	}
	return r, true
}
