package regex

// charset is a 256-entry membership table indexed by byte value. A class is
// therefore matched with a single table lookup.
type charset [256]bool

func (s *charset) add(c byte) { s[c] = true }

func (s *charset) addRange(lo, hi byte) {
	for c := int(lo); c <= int(hi); c++ {
		s[c] = true
	}
}

func (s *charset) union(o *charset) {
	for i := range s {
		if o[i] {
			s[i] = true
		}
	}
}

func (s *charset) negate() {
	for i := range s {
		s[i] = !s[i]
	}
}

// full reports whether every byte is a member.
func (s *charset) full() bool {
	for _, b := range s {
		if !b {
			return false
		}
	}
	return true
}

// setEscape returns the set denoted by \d \D \w \W \s \S, or nil when c is
// not one of those letters.
func setEscape(c byte) *charset {
	var s charset
	switch c {
	case 'd', 'D':
		s.addRange('0', '9')
	case 'w', 'W':
		s.addRange('a', 'z')
		s.addRange('A', 'Z')
		s.addRange('0', '9')
		s.add('_')
	case 's', 'S':
		for _, ch := range []byte{' ', '\t', '\n', '\r', '\f', '\v'} {
			s.add(ch)
		}
	default:
		return nil
	}
	if c == 'D' || c == 'W' || c == 'S' {
		s.negate()
	}
	return &s
}
