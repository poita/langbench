package value

import "unicode/utf8"

// Like reports whether s matches the LIKE pattern p. In p, '%' matches any
// sequence of zero or more characters and '_' matches exactly one character;
// everything else matches itself, ignoring case for the 26 ASCII letters only.
// The whole of s must match.
//
// The matcher keeps a single backtrack point (the most recent '%'), so it runs
// in O(len(s)·len(p)) time in the worst case and never builds a regular
// expression.
func Like(s, p string) bool {
	si, pi := 0, 0
	starP, starS := -1, 0 // pattern index of the last '%' and the s index it currently absorbs up to
	for si < len(s) {
		if pi < len(p) {
			switch p[pi] {
			case '%':
				starP, starS = pi, si
				pi++
				continue
			case '_':
				_, w := utf8.DecodeRuneInString(s[si:])
				si += w
				pi++
				continue
			}
			pr, pw := utf8.DecodeRuneInString(p[pi:])
			sr, sw := utf8.DecodeRuneInString(s[si:])
			if foldEqual(pr, sr) {
				si += sw
				pi += pw
				continue
			}
		}
		if starP < 0 {
			return false
		}
		_, w := utf8.DecodeRuneInString(s[starS:])
		starS += w
		si = starS
		pi = starP + 1
	}
	for pi < len(p) && p[pi] == '%' {
		pi++
	}
	return pi == len(p)
}

func foldEqual(a, b rune) bool {
	if a == b {
		return true
	}
	return asciiLower(a) == asciiLower(b)
}

func asciiLower(r rune) rune {
	if 'A' <= r && r <= 'Z' {
		return r + ('a' - 'A')
	}
	return r
}
