// Package scan holds the small character classification and text decoding
// helpers shared by the block parser, the inline parser and the renderer.
package scan

import (
	"strings"
	"unicode/utf8"
)

// IsSpace reports whether c is in the ASCII whitespace set of cmark:
// space, TAB, LF, VT, FF and CR.
func IsSpace(c byte) bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

// IsSpaceOrTab reports whether c is a space or a TAB.
func IsSpaceOrTab(c byte) bool { return c == ' ' || c == '\t' }

// IsPunct reports whether c is an ASCII punctuation character.
func IsPunct(c byte) bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') ||
		(c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

// IsDigit reports whether c is an ASCII digit.
func IsDigit(c byte) bool { return c >= '0' && c <= '9' }

// IsAlpha reports whether c is an ASCII letter.
func IsAlpha(c byte) bool { return (c|0x20) >= 'a' && (c|0x20) <= 'z' }

// IsAlnum reports whether c is an ASCII letter or digit.
func IsAlnum(c byte) bool { return IsAlpha(c) || IsDigit(c) }

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

// TrimSpace removes leading and trailing characters for which IsSpace holds.
func TrimSpace(s string) string {
	i, j := 0, len(s)
	for i < j && IsSpace(s[i]) {
		i++
	}
	for j > i && IsSpace(s[j-1]) {
		j--
	}
	return s[i:j]
}

// TrimRightSpace removes trailing characters for which IsSpace holds.
func TrimRightSpace(s string) string {
	j := len(s)
	for j > 0 && IsSpace(s[j-1]) {
		j--
	}
	return s[:j]
}

// MatchEntity tries to match the supported entity references at the start of
// s, which is the text right after an '&'. On success it returns the decoded
// text and the number of bytes of s consumed (including the ';').
func MatchEntity(s string) (decoded string, n int) {
	if len(s) == 0 {
		return "", 0
	}
	if s[0] == '#' {
		i, maxDigits, base := 1, 7, 10
		if len(s) > 1 && (s[1] == 'x' || s[1] == 'X') {
			i, maxDigits, base = 2, 6, 16
		}
		v, digits := 0, 0
		for i < len(s) && digits <= maxDigits {
			d := hexVal(s[i])
			if d < 0 || d >= base {
				break
			}
			v = v*base + d
			digits++
			i++
		}
		if digits == 0 || digits > maxDigits || i >= len(s) || s[i] != ';' {
			return "", 0
		}
		if v == 0 || v > utf8.MaxRune || (v >= 0xD800 && v <= 0xDFFF) {
			v = utf8.RuneError
		}
		return string(rune(v)), i + 1
	}
	switch {
	case strings.HasPrefix(s, "amp;"):
		return "&", 4
	case strings.HasPrefix(s, "lt;"):
		return "<", 3
	case strings.HasPrefix(s, "gt;"):
		return ">", 3
	case strings.HasPrefix(s, "quot;"):
		return "\"", 5
	}
	return "", 0
}

// DecodeEntities replaces the supported entity references in s by the
// characters they stand for.
func DecodeEntities(s string) string {
	i := strings.IndexByte(s, '&')
	if i < 0 {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	last := 0
	for ; i < len(s); i++ {
		if s[i] != '&' {
			continue
		}
		if dec, n := MatchEntity(s[i+1:]); n > 0 {
			b.WriteString(s[last:i])
			b.WriteString(dec)
			i += n
			last = i + 1
		}
	}
	b.WriteString(s[last:])
	return b.String()
}

// Unescape removes the backslash from every backslash escape (a backslash
// before an ASCII punctuation character) in s.
func Unescape(s string) string {
	i := strings.IndexByte(s, '\\')
	if i < 0 {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	last := 0
	for ; i < len(s)-1; i++ {
		if s[i] == '\\' && IsPunct(s[i+1]) {
			b.WriteString(s[last:i])
			last = i + 1
			i++
		}
	}
	b.WriteString(s[last:])
	return b.String()
}
