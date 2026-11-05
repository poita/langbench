package commonmark

// skipWhitespace returns the first index at or after i whose byte is not
// ASCII whitespace.
func skipWhitespace(s []byte, i int) int {
	for i < len(s) && isWhitespace(s[i]) {
		i++
	}
	return i
}

// scanDestination scans a link destination starting at s[i] and returns
// the raw destination text and the index just after it (after the closing
// '>' for the <...> form).
func scanDestination(s []byte, i int) (raw []byte, end int, ok bool) {
	if i < len(s) && s[i] == '<' {
		j := i + 1
		for j < len(s) {
			c := s[j]
			if c == '>' {
				if j+1 >= len(s) {
					return nil, 0, false
				}
				return s[i+1 : j], j + 1, true
			}
			if c == '\\' {
				j += 2
			} else if c == '\n' || c == '<' {
				return nil, 0, false
			} else {
				j++
			}
		}
		return nil, 0, false
	}
	j := i
	depth := 0
loop:
	for j < len(s) {
		c := s[j]
		switch {
		case c == '\\' && j+1 < len(s) && isASCIIPunct(s[j+1]):
			j += 2
		case c == '(':
			depth++
			j++
			if depth > 32 {
				return nil, 0, false
			}
		case c == ')':
			if depth == 0 {
				break loop
			}
			depth--
			j++
		case isWhitespace(c):
			break loop
		default:
			j++
		}
	}
	if j >= len(s) || depth != 0 {
		return nil, 0, false
	}
	return s[i:j], j, true
}

// scanTitle matches a link title starting at s[i] (which must be '"', '\”
// or '(') and returns the index just after it, or -1. A title is the
// longest match in which the closing delimiter (and, for parenthesised
// titles, also '(') occurs only when preceded by a backslash.
func scanTitle(s []byte, i int) int {
	open := s[i]
	closer := open
	if open == '(' {
		closer = ')'
	}
	best := -1
	for j := i + 1; j < len(s); j++ {
		c := s[j]
		escaped := s[j-1] == '\\' && j-1 > i
		if c == closer {
			if !escaped {
				return j + 1
			}
			best = j + 1
		} else if open == '(' && c == '(' && !escaped {
			return best
		}
	}
	return best
}

// scanAutolink matches an autolink whose '<' is at s[i]. It returns the
// text between the angle brackets, whether it is an email address, and the
// index just after the closing '>'.
func scanAutolink(s []byte, i int) (text []byte, email bool, end int, ok bool) {
	start := i + 1
	if j := scanURIAutolink(s, start); j > 0 {
		return s[start:j], false, j + 1, true
	}
	if j := scanEmailAutolink(s, start); j > 0 {
		return s[start:j], true, j + 1, true
	}
	return nil, false, 0, false
}

// scanURIAutolink matches scheme ':' chars at s[i:] followed by '>' and
// returns the index of the '>' or 0.
func scanURIAutolink(s []byte, i int) int {
	if i >= len(s) || !isAlpha(s[i]) {
		return 0
	}
	j := i + 1
	for j < len(s) && (isAlnum(s[j]) || s[j] == '.' || s[j] == '+' || s[j] == '-') {
		j++
	}
	if n := j - i; n < 2 || n > 32 {
		return 0
	}
	if j >= len(s) || s[j] != ':' {
		return 0
	}
	j++
	for j < len(s) && s[j] > 0x20 && s[j] != '<' && s[j] != '>' {
		j++
	}
	if j < len(s) && s[j] == '>' {
		return j
	}
	return 0
}

var emailLocal [256]bool

func init() {
	for _, c := range []byte(".!#$%&'*+/=?^_`{|}~-") {
		emailLocal[c] = true
	}
	for c := 0; c < 256; c++ {
		if isAlnum(byte(c)) {
			emailLocal[c] = true
		}
	}
}

// scanEmailAutolink matches an email address followed by '>' at s[i:] and
// returns the index of the '>' or 0.
func scanEmailAutolink(s []byte, i int) int {
	j := i
	for j < len(s) && emailLocal[s[j]] {
		j++
	}
	if j == i || j >= len(s) || s[j] != '@' {
		return 0
	}
	j++
	for {
		// One domain label: alnum, then [alnum-]*, ending in alnum, <= 63.
		k := j
		for k < len(s) && (isAlnum(s[k]) || s[k] == '-') {
			k++
		}
		if k == j || !isAlnum(s[j]) || !isAlnum(s[k-1]) || k-j > 63 {
			return 0
		}
		j = k
		if j < len(s) && s[j] == '.' {
			j++
			continue
		}
		break
	}
	if j < len(s) && s[j] == '>' {
		return j
	}
	return 0
}
