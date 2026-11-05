// Package porter implements the Porter stemming algorithm (M. F. Porter,
// 1980) in the form of the author's reference implementation, porter.c,
// including its two departures from the published paper (BLI -> BLE and
// LOGI -> LOG in step 2).
//
// The stemmer expects lower-case ASCII words a-z. Words of one or two letters
// are returned unchanged.
package porter

// Stem returns the Porter stem of word, which must consist of the ASCII
// letters a-z.
func Stem(word string) string {
	b := []byte(word)
	return string(b[:StemInPlace(b)])
}

// StemInPlace stems the word held in b, rewriting b's leading bytes, and
// returns the length of the stem. It never grows the word, so b[:n] is the
// result. It allocates nothing.
func StemInPlace(b []byte) int {
	if len(b) <= 2 {
		return len(b)
	}
	s := stemmer{b: b, n: len(b)}
	s.step1a()
	s.step1b()
	s.step1c()
	s.step2()
	s.step3()
	s.step4()
	s.step5()
	return s.n
}

// stemmer holds the word b[:n] as it is rewritten by the steps.
type stemmer struct {
	b []byte
	n int
}

// cons reports whether b[i] is a consonant.
func (s *stemmer) cons(i int) bool {
	switch s.b[i] {
	case 'a', 'e', 'i', 'o', 'u':
		return false
	case 'y':
		return i == 0 || !s.cons(i-1)
	}
	return true
}

// measure returns m for the prefix b[:n]: the number of VC sequences in
// [C](VC){m}[V].
func (s *stemmer) measure(n int) int {
	i := 0
	for i < n && s.cons(i) {
		i++
	}
	m := 0
	for {
		for i < n && !s.cons(i) {
			i++
		}
		if i >= n {
			return m
		}
		m++
		for i < n && s.cons(i) {
			i++
		}
		if i >= n {
			return m
		}
	}
}

// hasVowel reports whether b[:n] contains a vowel (*v*).
func (s *stemmer) hasVowel(n int) bool {
	for i := 0; i < n; i++ {
		if !s.cons(i) {
			return true
		}
	}
	return false
}

// doubleC reports whether b[:n] ends in a double consonant (*d).
func (s *stemmer) doubleC(n int) bool {
	return n >= 2 && s.b[n-1] == s.b[n-2] && s.cons(n-1)
}

// cvc reports whether b[:n] ends consonant-vowel-consonant with the last
// consonant not w, x or y (*o).
func (s *stemmer) cvc(n int) bool {
	if n < 3 || !s.cons(n-1) || s.cons(n-2) || !s.cons(n-3) {
		return false
	}
	switch s.b[n-1] {
	case 'w', 'x', 'y':
		return false
	}
	return true
}

// ends reports whether the word ends with suf.
func (s *stemmer) ends(suf string) bool {
	if len(suf) > s.n {
		return false
	}
	return string(s.b[s.n-len(suf):s.n]) == suf
}

// replace rewrites the word as b[:stem] followed by repl.
func (s *stemmer) replace(stem int, repl string) {
	s.n = stem + copy(s.b[stem:], repl)
}

func (s *stemmer) step1a() {
	if s.b[s.n-1] != 's' {
		return
	}
	switch {
	case s.ends("sses"):
		s.n -= 2
	case s.ends("ies"):
		s.n -= 2
	case s.b[s.n-2] != 's':
		s.n--
	}
}

func (s *stemmer) step1b() {
	if s.ends("eed") {
		if s.measure(s.n-3) > 0 {
			s.n--
		}
		return
	}
	var stem int
	switch {
	case s.ends("ed"):
		stem = s.n - 2
	case s.ends("ing"):
		stem = s.n - 3
	default:
		return
	}
	if !s.hasVowel(stem) {
		return
	}
	s.n = stem
	switch {
	case s.ends("at"):
		s.replace(s.n-2, "ate")
	case s.ends("bl"):
		s.replace(s.n-2, "ble")
	case s.ends("iz"):
		s.replace(s.n-2, "ize")
	case s.doubleC(s.n):
		switch s.b[s.n-1] {
		case 'l', 's', 'z':
		default:
			s.n--
		}
	case s.measure(s.n) == 1 && s.cvc(s.n):
		s.replace(s.n, "e")
	}
}

func (s *stemmer) step1c() {
	if s.b[s.n-1] == 'y' && s.hasVowel(s.n-1) {
		s.b[s.n-1] = 'i'
	}
}

type rule struct{ suffix, repl string }

var step2Rules = []rule{
	{"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"}, {"anci", "ance"},
	{"izer", "ize"}, {"bli", "ble"}, {"alli", "al"}, {"entli", "ent"},
	{"eli", "e"}, {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
	{"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"}, {"fulness", "ful"},
	{"ousness", "ous"}, {"aliti", "al"}, {"iviti", "ive"}, {"biliti", "ble"},
	{"logi", "log"},
}

var step3Rules = []rule{
	{"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
	{"ical", "ic"}, {"ful", ""}, {"ness", ""},
}

var step4Suffixes = []string{
	"al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
	"ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
}

// applyRules applies the first rule whose suffix matches, provided the
// measure of the remaining stem exceeds minM; later rules are never tried.
func (s *stemmer) applyRules(rules []rule, minM int) {
	for _, r := range rules {
		if s.ends(r.suffix) {
			if stem := s.n - len(r.suffix); s.measure(stem) > minM {
				s.replace(stem, r.repl)
			}
			return
		}
	}
}

func (s *stemmer) step2() { s.applyRules(step2Rules, 0) }
func (s *stemmer) step3() { s.applyRules(step3Rules, 0) }

func (s *stemmer) step4() {
	for _, suf := range step4Suffixes {
		if !s.ends(suf) {
			continue
		}
		stem := s.n - len(suf)
		if suf == "ion" && (stem == 0 || (s.b[stem-1] != 's' && s.b[stem-1] != 't')) {
			return
		}
		if s.measure(stem) > 1 {
			s.n = stem
		}
		return
	}
}

func (s *stemmer) step5() {
	if s.b[s.n-1] == 'e' {
		stem := s.n - 1
		if m := s.measure(stem); m > 1 || (m == 1 && !s.cvc(stem)) {
			s.n = stem
		}
	}
	if s.b[s.n-1] == 'l' && s.doubleC(s.n) && s.measure(s.n) > 1 {
		s.n--
	}
}
