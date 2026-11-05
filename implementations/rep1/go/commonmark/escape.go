package commonmark

import "bytes"

const hexUpper = "0123456789ABCDEF"

// appendEscaped appends s with & < > " replaced by character references.
func appendEscaped(out, s []byte) []byte {
	for {
		i := bytes.IndexAny(s, "&<>\"")
		if i < 0 {
			return append(out, s...)
		}
		out = append(out, s[:i]...)
		switch s[i] {
		case '&':
			out = append(out, "&amp;"...)
		case '<':
			out = append(out, "&lt;"...)
		case '>':
			out = append(out, "&gt;"...)
		default:
			out = append(out, "&quot;"...)
		}
		s = s[i+1:]
	}
}

var hrefSafe [256]bool

func init() {
	for _, c := range []byte("-_.~!#$%()*+,/:;=?@") {
		hrefSafe[c] = true
	}
	for c := 0; c < 256; c++ {
		if isAlnum(byte(c)) {
			hrefSafe[c] = true
		}
	}
}

// hasPrefixFold reports whether s starts with the lower-case ASCII string
// prefix, ignoring the case of s.
func hasPrefixFold(s []byte, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	for i := 0; i < len(prefix); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != prefix[i] {
			return false
		}
	}
	return true
}

// isDangerousURL reports whether a destination uses a scheme whose links
// are suppressed: javascript:, vbscript:, file: and data: (except for a
// few image types).
func isDangerousURL(u []byte) bool {
	for _, p := range []string{"javascript:", "vbscript:", "file:", "data:"} {
		if hasPrefixFold(u, p) {
			if p == "data:" {
				for _, ok := range []string{"data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"} {
					if hasPrefixFold(u, ok) {
						return false
					}
				}
			}
			return true
		}
	}
	return false
}

// appendHref appends the URL-encoded form of a destination.
func appendHref(out, dest []byte) []byte {
	if isDangerousURL(dest) {
		return out
	}
	start := 0
	for i := 0; i < len(dest); i++ {
		c := dest[i]
		if hrefSafe[c] {
			continue
		}
		out = append(out, dest[start:i]...)
		start = i + 1
		switch c {
		case '&':
			out = append(out, "&amp;"...)
		case '\'':
			out = append(out, "&#x27;"...)
		default:
			out = append(out, '%', hexUpper[c>>4], hexUpper[c&15])
		}
	}
	return append(out, dest[start:]...)
}
