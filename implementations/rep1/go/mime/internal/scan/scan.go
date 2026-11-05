// Package scan holds the small lexical helpers shared by the header-value
// parsers: quoted strings, comments and domain literals.
//
// All functions work on bytes of a UTF-8 string. Every delimiter involved is
// ASCII, and no byte of a multi-byte UTF-8 sequence is ASCII, so byte
// scanning is exact.
package scan

// Quoted reads a quoted string whose opening '"' is at s[i]. It returns the
// unescaped contents and the index just after the closing quote. A backslash
// and the byte after it stand for that byte; a trailing backslash stands for
// itself; an unterminated string extends to the end of s.
func Quoted(s string, i int) (text string, next int) {
	start := i + 1
	var buf []byte
	escaped := false
	for j := start; j < len(s); j++ {
		c := s[j]
		switch {
		case c == '"':
			if !escaped {
				return s[start:j], j + 1
			}
			return string(buf), j + 1
		case c == '\\' && j+1 < len(s):
			if !escaped {
				buf = append(buf, s[start:j]...)
				escaped = true
			}
			j++
			buf = append(buf, s[j])
		default:
			if escaped {
				buf = append(buf, c)
			}
		}
	}
	if !escaped {
		return s[start:], len(s)
	}
	return string(buf), len(s)
}

// Comment skips a parenthesised comment whose '(' is at s[i] and returns the
// index just after the matching ')'. Comments nest, a backslash escapes the
// byte after it, and an unterminated comment runs to the end of s.
func Comment(s string, i int) int {
	depth := 0
	for j := i; j < len(s); j++ {
		switch s[j] {
		case '\\':
			j++
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return j + 1
			}
		}
	}
	return len(s)
}

// Literal skips a domain literal whose '[' is at s[i] and returns the index
// just after the closing ']'. A backslash escapes the byte after it and an
// unterminated literal runs to the end of s.
func Literal(s string, i int) int {
	for j := i + 1; j < len(s); j++ {
		switch s[j] {
		case '\\':
			j++
		case ']':
			return j + 1
		}
	}
	return len(s)
}

// IsBlank reports whether c is SPACE or TAB.
func IsBlank(c byte) bool { return c == ' ' || c == '\t' }

// Trim strips leading and trailing SPACE and TAB from s.
func Trim(s string) string {
	for len(s) > 0 && IsBlank(s[0]) {
		s = s[1:]
	}
	for len(s) > 0 && IsBlank(s[len(s)-1]) {
		s = s[:len(s)-1]
	}
	return s
}

// LowerASCII lower-cases the ASCII letters of s and leaves every other byte
// alone.
func LowerASCII(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 'A' && c <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

// HexVal returns the value of the hexadecimal digit c, or -1.
func HexVal(c byte) int {
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
