package syntax

// CharSet is a set of byte values, stored as a 256-bit bitmap.
// The zero value is the empty set.
type CharSet [4]uint64

// Add inserts c into the set.
func (s *CharSet) Add(c byte) { s[c>>6] |= 1 << (c & 63) }

// AddRange inserts every byte in lo..hi (inclusive) into the set.
func (s *CharSet) AddRange(lo, hi byte) {
	for c := int(lo); c <= int(hi); c++ {
		s.Add(byte(c))
	}
}

// Has reports whether c is in the set.
func (s *CharSet) Has(c byte) bool { return s[c>>6]&(1<<(c&63)) != 0 }

// Union adds every member of o to s.
func (s *CharSet) Union(o *CharSet) {
	for i := range s {
		s[i] |= o[i]
	}
}

// Negate replaces s by its complement over all 256 byte values.
func (s *CharSet) Negate() {
	for i := range s {
		s[i] = ^s[i]
	}
}

// negateASCII replaces s by its complement over the ASCII range 0..127.
func (s *CharSet) negateASCII() {
	s[0] = ^s[0]
	s[1] = ^s[1]
	s[2], s[3] = 0, 0
}

// IsEmpty reports whether the set has no members.
func (s *CharSet) IsEmpty() bool { return s[0]|s[1]|s[2]|s[3] == 0 }

// AllChars returns the set of all 256 byte values.
func AllChars() CharSet {
	var s CharSet
	s.Negate()
	return s
}

// Predefined sets used by the escapes \d, \w and \s.
func digitSet() (s CharSet) {
	s.AddRange('0', '9')
	return
}

func wordSet() (s CharSet) {
	s.AddRange('0', '9')
	s.AddRange('A', 'Z')
	s.AddRange('a', 'z')
	s.Add('_')
	return
}

func spaceSet() (s CharSet) {
	for _, c := range []byte(" \t\n\r\f\v") {
		s.Add(c)
	}
	return
}

// escapeSet returns the set denoted by the set escape \c, where c is one of
// d D w W s S. ok is false for any other byte.
func escapeSet(c byte) (set CharSet, ok bool) {
	switch c {
	case 'd', 'D':
		set = digitSet()
	case 'w', 'W':
		set = wordSet()
	case 's', 'S':
		set = spaceSet()
	default:
		return set, false
	}
	if c == 'D' || c == 'W' || c == 'S' {
		set.negateASCII()
	}
	return set, true
}
