package commonmark

import (
	"bytes"
	"unicode/utf8"
)

// matchEntity tries to match a character reference whose '&' is at s[i].
// It supports decimal and hexadecimal numeric references and the four
// named references &amp; &lt; &gt; &quot;. On success it returns the
// decoded bytes and the index just after the ';'.
func matchEntity(s []byte, i int) (decoded []byte, end int, ok bool) {
	j := i + 1
	if j >= len(s) {
		return nil, 0, false
	}
	if s[j] == '#' {
		j++
		maxDigits := 7
		base := 10
		if j < len(s) && (s[j] == 'x' || s[j] == 'X') {
			j++
			maxDigits = 6
			base = 16
		}
		start := j
		cp := 0
		for j < len(s) && j-start < maxDigits {
			c := s[j]
			if base == 10 && !isDigit(c) || base == 16 && !isHexDigit(c) {
				break
			}
			cp = cp*base + hexVal(c)
			j++
		}
		if j == start || j >= len(s) || s[j] != ';' {
			return nil, 0, false
		}
		if cp == 0 || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF {
			cp = utf8.RuneError
		}
		return utf8.AppendRune(nil, rune(cp)), j + 1, true
	}
	rest := s[j:]
	switch {
	case bytes.HasPrefix(rest, []byte("amp;")):
		return []byte("&"), j + 4, true
	case bytes.HasPrefix(rest, []byte("lt;")):
		return []byte("<"), j + 3, true
	case bytes.HasPrefix(rest, []byte("gt;")):
		return []byte(">"), j + 3, true
	case bytes.HasPrefix(rest, []byte("quot;")):
		return []byte("\""), j + 5, true
	}
	return nil, 0, false
}

// decodeEntities replaces every recognised character reference in s. The
// result may alias s when there is nothing to replace.
func decodeEntities(s []byte) []byte {
	i := bytes.IndexByte(s, '&')
	if i < 0 {
		return s
	}
	out := make([]byte, 0, len(s))
	for i >= 0 {
		out = append(out, s[:i]...)
		s = s[i:]
		if dec, end, ok := matchEntity(s, 0); ok {
			out = append(out, dec...)
			s = s[end:]
		} else {
			out = append(out, '&')
			s = s[1:]
		}
		i = bytes.IndexByte(s, '&')
	}
	return append(out, s...)
}

// unescapeBackslashes removes the backslash from every backslash escape
// (a backslash before an ASCII punctuation character).
func unescapeBackslashes(s []byte) []byte {
	i := bytes.IndexByte(s, '\\')
	if i < 0 {
		return s
	}
	out := make([]byte, 0, len(s))
	for i >= 0 {
		out = append(out, s[:i]...)
		s = s[i:]
		if len(s) > 1 && isASCIIPunct(s[1]) {
			out = append(out, s[1])
			s = s[2:]
		} else {
			out = append(out, '\\')
			s = s[1:]
		}
		i = bytes.IndexByte(s, '\\')
	}
	return append(out, s...)
}

// cleanDestination turns a raw link destination into its final form:
// trimmed, entities decoded, backslash escapes removed.
func cleanDestination(raw []byte) []byte {
	return unescapeBackslashes(decodeEntities(trimWhitespace(raw)))
}

// cleanTitle processes the text between a title's delimiters.
func cleanTitle(raw []byte) []byte {
	return unescapeBackslashes(decodeEntities(raw))
}
