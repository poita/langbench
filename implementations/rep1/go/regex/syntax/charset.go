package syntax

// CharSet is a set of byte values, stored as a 256-bit bitmap.
//
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

// Negate replaces the set with its complement over all 256 byte values.
func (s *CharSet) Negate() {
	for i := range s {
		s[i] = ^s[i]
	}
}

// IsEmpty reports whether the set has no members.
func (s *CharSet) IsEmpty() bool { return s[0]|s[1]|s[2]|s[3] == 0 }

// FullSet returns the set containing every byte value.
func FullSet() CharSet { return CharSet{^uint64(0), ^uint64(0), ^uint64(0), ^uint64(0)} }

// Predefined escape classes (\d, \w, \s). Their complements are obtained
// with Negate.
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
