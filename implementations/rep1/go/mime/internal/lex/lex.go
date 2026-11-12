// Package lex holds the small lexical helpers shared by the header, address,
// date and RFC 2047 packages: blank handling, comments and quoted strings.
package lex

import "strings"

// IsBlank reports whether c is SPACE or TAB.
func IsBlank(c byte) bool { return c == ' ' || c == '\t' }

// Strip removes leading and trailing SPACE and TAB characters from s.
func Strip(s string) string { return strings.Trim(s, " \t") }

// Collapse replaces every maximal run of SPACE and TAB in s with a single
// SPACE and then strips one leading and one trailing SPACE.
func Collapse(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	inRun := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if IsBlank(c) {
			if !inRun {
				b.WriteByte(' ')
				inRun = true
			}
			continue
		}
		inRun = false
		b.WriteByte(c)
	}
	out := b.String()
	out = strings.TrimPrefix(out, " ")
	out = strings.TrimSuffix(out, " ")
	return out
}

// SkipComment is called with s[i] == '('. It returns the index just past the
// matching ')', counting nested parentheses and treating a backslash and the
// byte after it as a unit. An unterminated comment runs to the end of s.
func SkipComment(s string, i int) int {
	depth := 0
	for i < len(s) {
		switch s[i] {
		case '\\':
			i++ // skip the escaped byte as well
			if i < len(s) && s[i] >= 0x80 {
				// skip the remaining continuation bytes of a multi-byte rune
				for i+1 < len(s) && s[i+1]&0xC0 == 0x80 {
					i++
				}
			}
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i + 1
			}
		}
		i++
	}
	return len(s)
}

// QuotedString is called with s[i] == '"'. It returns the unescaped contents
// of the quoted string and the index just past the closing quote (or the end
// of s if the string is never closed). A backslash and the character after it
// stand for that character; a backslash that ends s stands for itself.
func QuotedString(s string, i int) (text string, next int) {
	i++
	start := i
	// Fast path: no escapes before the closing quote.
	for j := i; j < len(s); j++ {
		if s[j] == '\\' {
			break
		}
		if s[j] == '"' {
			return s[start:j], j + 1
		}
	}
	var b strings.Builder
	for i < len(s) {
		c := s[i]
		switch {
		case c == '"':
			return b.String(), i + 1
		case c == '\\' && i+1 < len(s):
			i++
			b.WriteByte(s[i])
			// copy a multi-byte character whole
			for i+1 < len(s) && s[i] >= 0x80 && s[i+1]&0xC0 == 0x80 {
				i++
				b.WriteByte(s[i])
			}
			i++
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String(), len(s)
}

// SkipQuoted is like QuotedString but only returns the index past the string.
func SkipQuoted(s string, i int) int {
	_, n := QuotedString(s, i)
	return n
}
