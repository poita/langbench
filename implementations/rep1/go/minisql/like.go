package minisql

// seqLen is the length of the UTF-8 sequence starting at s[i], clamped to
// the end of s. Stray continuation bytes count as one byte.
func seqLen(s string, i int) int {
	c := s[i]
	n := 1
	switch {
	case c >= 0xF0:
		n = 4
	case c >= 0xE0:
		n = 3
	case c >= 0xC0:
		n = 2
	}
	if i+n > len(s) {
		n = len(s) - i
	}
	return n
}

func fold(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 'a' - 'A'
	}
	return c
}

// like reports whether s matches the LIKE pattern p: '%' matches any run of
// characters, '_' any single character, and the 26 ASCII letters match
// case-insensitively. It runs on the UTF-8 bytes with a single backtrack
// point (the last '%'), so it takes O(len(s)*len(p)) time at worst and does
// not allocate.
func like(s, p string) bool {
	si, pi := 0, 0
	star, mark := -1, 0
	for si < len(s) {
		if pi < len(p) {
			switch p[pi] {
			case '%':
				star, mark = pi, si
				pi++
				continue
			case '_':
				si += seqLen(s, si)
				pi++
				continue
			default:
				if fold(p[pi]) == fold(s[si]) {
					si++
					pi++
					continue
				}
			}
		}
		if star < 0 {
			return false
		}
		mark += seqLen(s, mark)
		si, pi = mark, star+1
	}
	for pi < len(p) && p[pi] == '%' {
		pi++
	}
	return pi == len(p)
}
