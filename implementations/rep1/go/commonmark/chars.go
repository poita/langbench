package commonmark

// Character classes used throughout the parser. All of CommonMark's
// syntax decisions are ASCII-driven, so the parser works on bytes and
// copies non-ASCII bytes through unchanged.

var punctTable [256]bool

func init() {
	for _, c := range []byte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~") {
		punctTable[c] = true
	}
}

// isASCIIPunct reports whether c is an ASCII punctuation character.
func isASCIIPunct(c byte) bool { return punctTable[c] }

// isSpaceOrTab reports whether c is a space or a tab.
func isSpaceOrTab(c byte) bool { return c == ' ' || c == '\t' }

// isWhitespace reports whether c is in the ASCII whitespace set used by
// the reference implementation: space, TAB, LF, VT, FF and CR.
func isWhitespace(c byte) bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isAlpha(c byte) bool { return (c|0x20) >= 'a' && (c|0x20) <= 'z' }

func isAlnum(c byte) bool { return isDigit(c) || isAlpha(c) }

func isHexDigit(c byte) bool {
	return isDigit(c) || ((c|0x20) >= 'a' && (c|0x20) <= 'f')
}

func hexVal(c byte) int {
	switch {
	case isDigit(c):
		return int(c - '0')
	default:
		return int(c|0x20-'a') + 10
	}
}

// trimWhitespace removes leading and trailing ASCII whitespace.
func trimWhitespace(b []byte) []byte {
	for len(b) > 0 && isWhitespace(b[0]) {
		b = b[1:]
	}
	return trimRightWhitespace(b)
}

// trimRightWhitespace removes trailing ASCII whitespace.
func trimRightWhitespace(b []byte) []byte {
	for len(b) > 0 && isWhitespace(b[len(b)-1]) {
		b = b[:len(b)-1]
	}
	return b
}
