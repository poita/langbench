package markdown

import (
	"strings"
	"unicode/utf8"
)

// matchEntity matches an entity reference at s[i] == '&'. It recognises
// decimal and hexadecimal numeric references and the four named references
// &amp; &lt; &gt; &quot;. It returns the decoded text and the index after
// the terminating ';'.
func matchEntity(s string, i int) (text string, end int, ok bool) {
	j := i + 1
	if j >= len(s) {
		return
	}
	if s[j] == '#' {
		j++
		hex := false
		if j < len(s) && (s[j] == 'x' || s[j] == 'X') {
			hex = true
			j++
		}
		maxDigits := 7
		if hex {
			maxDigits = 6
		}
		start := j
		n := 0
		for j < len(s) && j-start < maxDigits {
			d, isDigit := digitValue(s[j], hex)
			if !isDigit {
				break
			}
			n = n*base(hex) + d
			j++
		}
		if j == start || j >= len(s) || s[j] != ';' {
			return
		}
		r := rune(n)
		if n == 0 || n > utf8.MaxRune || (n >= 0xD800 && n <= 0xDFFF) {
			r = utf8.RuneError
		}
		return string(r), j + 1, true
	}
	for _, e := range [...]struct{ name, text string }{{"amp;", "&"}, {"lt;", "<"}, {"gt;", ">"}, {"quot;", "\""}} {
		if strings.HasPrefix(s[j:], e.name) {
			return e.text, j + len(e.name), true
		}
	}
	return
}

func base(hex bool) int {
	if hex {
		return 16
	}
	return 10
}

func digitValue(c byte, hex bool) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case hex && c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case hex && c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

// unescapeEntities replaces every entity reference in s by its text.
func unescapeEntities(s string) string {
	i := strings.IndexByte(s, '&')
	if i < 0 {
		return s
	}
	var b strings.Builder
	for i >= 0 {
		b.WriteString(s[:i])
		if text, end, ok := matchEntity(s, i); ok {
			b.WriteString(text)
			s = s[end:]
		} else {
			b.WriteByte('&')
			s = s[i+1:]
		}
		i = strings.IndexByte(s, '&')
	}
	b.WriteString(s)
	return b.String()
}

// unescapeBackslashes removes the backslash of every backslash escape.
func unescapeBackslashes(s string) string {
	i := strings.IndexByte(s, '\\')
	if i < 0 {
		return s
	}
	var b strings.Builder
	for i >= 0 {
		b.WriteString(s[:i])
		if i+1 < len(s) && isASCIIPunct(s[i+1]) {
			b.WriteByte(s[i+1])
			s = s[i+2:]
		} else {
			b.WriteByte('\\')
			s = s[i+1:]
		}
		i = strings.IndexByte(s, '\\')
	}
	b.WriteString(s)
	return b.String()
}
