package syntax

// CharSet is a set of byte values, stored as a 256-entry membership table so
// that a membership test is a single indexed load.
type CharSet [256]bool

// Has reports whether c is in the set.
func (s *CharSet) Has(c byte) bool { return s[c] }

// Add inserts c into the set.
func (s *CharSet) Add(c byte) { s[c] = true }

// AddRange inserts every byte in lo..hi (inclusive) into the set.
func (s *CharSet) AddRange(lo, hi byte) {
	for c := int(lo); c <= int(hi); c++ {
		s[c] = true
	}
}

// AddSet inserts every member of t into the set.
func (s *CharSet) AddSet(t *CharSet) {
	for i, v := range t {
		if v {
			s[i] = true
		}
	}
}

// Negate replaces the set with its complement over all 256 byte values.
func (s *CharSet) Negate() {
	for i := range s {
		s[i] = !s[i]
	}
}

// IsFull reports whether the set contains every byte value.
func (s *CharSet) IsFull() bool {
	for _, v := range s {
		if !v {
			return false
		}
	}
	return true
}

// FullSet returns a set containing every byte value.
func FullSet() CharSet {
	var s CharSet
	for i := range s {
		s[i] = true
	}
	return s
}

// escapeSet returns the set denoted by the set escape \d, \D, \w, \W, \s or
// \S, and whether c is such an escape letter.
func escapeSet(c byte) (CharSet, bool) {
	var s CharSet
	switch c {
	case 'd', 'D':
		s.AddRange('0', '9')
	case 'w', 'W':
		s.AddRange('0', '9')
		s.AddRange('a', 'z')
		s.AddRange('A', 'Z')
		s.Add('_')
	case 's', 'S':
		for _, ch := range []byte(" \t\n\r\f\v") {
			s.Add(ch)
		}
	default:
		return s, false
	}
	if c == 'D' || c == 'W' || c == 'S' {
		s.Negate()
	}
	return s, true
}
