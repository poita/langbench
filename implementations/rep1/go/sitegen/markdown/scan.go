package markdown

import "unicode/utf8"

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

func isSpaceOrTab(c byte) bool { return c == ' ' || c == '\t' }

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isAlpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

func isAlnum(c byte) bool { return isAlpha(c) || isDigit(c) }

func isHex(c byte) bool {
	return isDigit(c) || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

// isPunct reports whether c is an ASCII punctuation character.
func isPunct(c byte) bool {
	return c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~'
}

// matchEntity tries to match an entity reference at s[i], which must be '&'.
// It returns the decoded text and the number of bytes consumed, or 0.
func matchEntity(s string, i int) (string, int) {
	j := i + 1
	if j >= len(s) {
		return "", 0
	}
	if s[j] == '#' {
		j++
		hex := false
		maxDigits := 7
		if j < len(s) && (s[j] == 'x' || s[j] == 'X') {
			hex = true
			maxDigits = 6
			j++
		}
		start := j
		v := 0
		for j < len(s) && j-start < maxDigits {
			c := s[j]
			var d int
			switch {
			case isDigit(c):
				d = int(c - '0')
			case hex && isHex(c):
				d = int((c|0x20)-'a') + 10
			default:
				d = -1
			}
			if d < 0 {
				break
			}
			if hex {
				v = v*16 + d
			} else {
				v = v*10 + d
			}
			j++
		}
		if j == start || j >= len(s) || s[j] != ';' {
			return "", 0
		}
		if v == 0 || v >= 0xD800 && v < 0xE000 || v > 0x10FFFF {
			v = utf8.RuneError
		}
		return string(rune(v)), j + 1 - i
	}
	rest := s[j:]
	switch {
	case hasPrefix(rest, "amp;"):
		return "&", len("&amp;")
	case hasPrefix(rest, "lt;"):
		return "<", len("&lt;")
	case hasPrefix(rest, "gt;"):
		return ">", len("&gt;")
	case hasPrefix(rest, "quot;"):
		return "\"", len("&quot;")
	}
	return "", 0
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

// decodeEntities replaces entity references in s by the characters they denote.
func decodeEntities(s string) string {
	first := -1
	for i := 0; i < len(s); i++ {
		if s[i] == '&' {
			first = i
			break
		}
	}
	if first < 0 {
		return s
	}
	out := make([]byte, 0, len(s))
	out = append(out, s[:first]...)
	for i := first; i < len(s); {
		if s[i] == '&' {
			if dec, n := matchEntity(s, i); n > 0 {
				out = append(out, dec...)
				i += n
				continue
			}
		}
		out = append(out, s[i])
		i++
	}
	return string(out)
}

// unescapeBackslashes removes the backslash from every backslash escape.
func unescapeBackslashes(s string) string {
	has := false
	for i := 0; i+1 < len(s); i++ {
		if s[i] == '\\' && isPunct(s[i+1]) {
			has = true
			break
		}
	}
	if !has {
		return s
	}
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && isPunct(s[i+1]) {
			i++
		}
		out = append(out, s[i])
	}
	return string(out)
}

func trimSpace(s string) string {
	i, j := 0, len(s)
	for i < j && isSpace(s[i]) {
		i++
	}
	for j > i && isSpace(s[j-1]) {
		j--
	}
	return s[i:j]
}

func rtrimSpace(s string) string {
	j := len(s)
	for j > 0 && isSpace(s[j-1]) {
		j--
	}
	return s[:j]
}
