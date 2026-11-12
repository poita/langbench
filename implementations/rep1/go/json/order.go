package jsoncanon

// CompareKeys compares two valid UTF-8 strings by their UTF-16 code unit
// sequences, treating each unit as an unsigned 16-bit integer. It returns -1,
// 0 or +1. A proper prefix sorts first.
//
// UTF-16 order differs from UTF-8 byte order only for supplementary
// characters (U+10000 and above), which sort before U+E000–U+FFFF. Because
// the first differing byte of two valid UTF-8 strings is either a lead byte
// at a shared character boundary or a continuation byte after equal lead
// bytes, it suffices to re-rank the lead bytes 0xEE and 0xEF above 0xF4 there.
func CompareKeys(a, b string) int {
	n := min(len(a), len(b))
	for i := 0; i < n; i++ {
		x, y := a[i], b[i]
		if x != y {
			if rank(x) < rank(y) {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	}
	return 0
}

// rank maps a UTF-8 byte to a value whose order matches UTF-16 order of the
// characters they start.
func rank(c byte) int {
	if c == 0xEE || c == 0xEF {
		return int(c) + 0x10
	}
	return int(c)
}
