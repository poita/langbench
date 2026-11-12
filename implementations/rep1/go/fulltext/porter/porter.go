// Package porter implements the original Porter stemming algorithm (1980) in
// the form of Martin Porter's reference implementation porter.c, including its
// two documented departures from the published paper (BLI -> BLE in step 2 and
// the added LOGI -> LOG rule).
//
// The only entry point is [Stem].
package porter

// Stem returns the Porter stem of word, which must consist of ASCII lower-case
// letters only. Words of one or two letters are returned unchanged. Behaviour
// for other input is unspecified (it never panics).
func Stem(word string) string {
	if len(word) <= 2 {
		return word
	}
	s := stemmer{b: []byte(word)}
	s.step1a()
	s.step1b()
	s.step1c()
	s.apply(step2Rules, 0)
	s.apply(step3Rules, 0)
	s.apply(step4Rules, 1)
	s.step5a()
	s.step5b()
	return string(s.b)
}

// stemmer holds the word being stemmed. All steps edit b in place.
type stemmer struct {
	b []byte
}

// rule is one "(m>min) SUFFIX -> REPL" entry of steps 2 to 4.
type rule struct {
	suffix, repl string
	// needST marks the step 4 ION rule, whose stem must end in s or t.
	needST bool
}

var step2Rules = []rule{
	{"ational", "ate", false},
	{"tional", "tion", false},
	{"enci", "ence", false},
	{"anci", "ance", false},
	{"izer", "ize", false},
	{"bli", "ble", false},
	{"alli", "al", false},
	{"entli", "ent", false},
	{"eli", "e", false},
	{"ousli", "ous", false},
	{"ization", "ize", false},
	{"ation", "ate", false},
	{"ator", "ate", false},
	{"alism", "al", false},
	{"iveness", "ive", false},
	{"fulness", "ful", false},
	{"ousness", "ous", false},
	{"aliti", "al", false},
	{"iviti", "ive", false},
	{"biliti", "ble", false},
	{"logi", "log", false},
}

var step3Rules = []rule{
	{"icate", "ic", false},
	{"ative", "", false},
	{"alize", "al", false},
	{"iciti", "ic", false},
	{"ical", "ic", false},
	{"ful", "", false},
	{"ness", "", false},
}

var step4Rules = []rule{
	{"al", "", false},
	{"ance", "", false},
	{"ence", "", false},
	{"er", "", false},
	{"ic", "", false},
	{"able", "", false},
	{"ible", "", false},
	{"ant", "", false},
	{"ement", "", false},
	{"ment", "", false},
	{"ent", "", false},
	{"ion", "", true},
	{"ou", "", false},
	{"ism", "", false},
	{"ate", "", false},
	{"iti", "", false},
	{"ous", "", false},
	{"ive", "", false},
	{"ize", "", false},
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
	m, i := 0, 0
	for i < n && s.cons(i) {
		i++
	}
	for i < n {
		for i < n && !s.cons(i) {
			i++
		}
		if i >= n {
			break
		}
		m++
		for i < n && s.cons(i) {
			i++
		}
	}
	return m
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

// doubleC reports whether b[:n] ends in two identical consonants (*d).
func (s *stemmer) doubleC(n int) bool {
	return n >= 2 && s.b[n-1] == s.b[n-2] && s.cons(n-1)
}

// cvc reports *o for b[:n]: it ends consonant-vowel-consonant and the final
// consonant is not w, x or y.
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

func (s *stemmer) hasSuffix(suffix string) bool {
	n := len(s.b)
	return n >= len(suffix) && string(s.b[n-len(suffix):]) == suffix
}

// replace removes the suffix of length cut and appends repl.
func (s *stemmer) replace(cut int, repl string) {
	s.b = append(s.b[:len(s.b)-cut], repl...)
}

func (s *stemmer) step1a() {
	switch {
	case s.hasSuffix("sses"):
		s.replace(4, "ss")
	case s.hasSuffix("ies"):
		s.replace(3, "i")
	case s.hasSuffix("ss"):
	case s.hasSuffix("s"):
		s.replace(1, "")
	}
}

func (s *stemmer) step1b() {
	var cut int
	switch {
	case s.hasSuffix("eed"):
		if s.measure(len(s.b)-3) > 0 {
			s.replace(1, "")
		}
		return
	case s.hasSuffix("ed"):
		cut = 2
	case s.hasSuffix("ing"):
		cut = 3
	default:
		return
	}
	if !s.hasVowel(len(s.b) - cut) {
		return
	}
	s.replace(cut, "")
	switch {
	case s.hasSuffix("at"):
		s.replace(0, "e")
	case s.hasSuffix("bl"):
		s.replace(0, "e")
	case s.hasSuffix("iz"):
		s.replace(0, "e")
	case s.doubleC(len(s.b)):
		switch s.b[len(s.b)-1] {
		case 'l', 's', 'z':
		default:
			s.replace(1, "")
		}
	case s.measure(len(s.b)) == 1 && s.cvc(len(s.b)):
		s.replace(0, "e")
	}
}

func (s *stemmer) step1c() {
	n := len(s.b)
	if s.b[n-1] == 'y' && s.hasVowel(n-1) {
		s.b[n-1] = 'i'
	}
}

// apply runs one of the suffix-table steps: the first rule whose suffix
// matches is selected, and fires only if the stem measure exceeds minM.
func (s *stemmer) apply(rules []rule, minM int) {
	for _, r := range rules {
		if !s.hasSuffix(r.suffix) {
			continue
		}
		n := len(s.b) - len(r.suffix)
		if s.measure(n) > minM && (!r.needST || (n > 0 && (s.b[n-1] == 's' || s.b[n-1] == 't'))) {
			s.replace(len(r.suffix), r.repl)
		}
		return
	}
}

func (s *stemmer) step5a() {
	n := len(s.b)
	if s.b[n-1] != 'e' {
		return
	}
	m := s.measure(n - 1)
	if m > 1 || (m == 1 && !s.cvc(n-1)) {
		s.b = s.b[:n-1]
	}
}

func (s *stemmer) step5b() {
	n := len(s.b)
	if s.b[n-1] == 'l' && s.doubleC(n) && s.measure(n) > 1 {
		s.b = s.b[:n-1]
	}
}
