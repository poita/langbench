package jsoncanon

import "unicode/utf8"

// compareKeys orders two valid UTF-8 keys by their UTF-16 code unit
// sequences without converting them: it finds the first differing byte, backs
// up to the start of the character containing it, and compares the two code
// points with U+E000–U+FFFF ranked above all supplementary characters. A
// proper prefix sorts first. It returns a negative, zero or positive int.
func compareKeys(a, b []byte) int {
	n := min(len(a), len(b))
	i := 0
	for i < n && a[i] == b[i] {
		i++
	}
	if i == n {
		return len(a) - len(b)
	}
	if a[i] < 0x80 && b[i] < 0x80 {
		return int(a[i]) - int(b[i])
	}
	// The shared prefix ends on the same character boundary in both keys.
	j := i
	for j > 0 && isCont(a[j]) {
		j--
	}
	ra, _ := utf8.DecodeRune(a[j:])
	rb, _ := utf8.DecodeRune(b[j:])
	return utf16Rank(ra) - utf16Rank(rb)
}

// utf16Rank maps a code point to a value whose integer order equals the
// UTF-16 code unit order of the code points.
func utf16Rank(r rune) int {
	if r >= 0xE000 && r <= 0xFFFF {
		return int(r) + 0x110000
	}
	return int(r)
}
