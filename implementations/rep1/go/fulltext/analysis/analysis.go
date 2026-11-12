// Package analysis turns text into index terms: it tokenises, folds case
// (ASCII only), removes apostrophes and Porter-stems.
//
// The same analysis is applied to documents and to query phrases, so the two
// always agree on what a word is.
package analysis

import (
	"sync"
	"unicode/utf8"

	"fulltext/porter"
)

// Token is one token of analysed text.
type Token struct {
	// Start and End are the half-open byte offsets of the token in the
	// analysed text (apostrophes included).
	Start, End int
	// Text is the folded token text: apostrophes deleted, A-Z mapped to a-z.
	Text string
	// Term is the index term: the Porter stem of Text when Text is made only of
	// the letters a-z, Text itself otherwise.
	Term string
}

// IsTokenChar reports whether r may occur inside a token.
func IsTokenChar(r rune) bool {
	switch {
	case r >= '0' && r <= '9', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z':
		return true
	case r >= 0xC0 && r <= 0xD6, r >= 0xD8 && r <= 0xF6, r >= 0xF8 && r <= 0x24F:
		return true
	case r >= 0x370 && r <= 0x3FF, r >= 0x400 && r <= 0x4FF:
		return true
	}
	return false
}

// IsApostrophe reports whether r is U+0027 or U+2019.
func IsApostrophe(r rune) bool { return r == '\'' || r == '’' }

// IsSpace reports whether r is one of the seven whitespace code points that
// the query syntax and the snippet builder recognise: U+0009 to U+000D,
// U+0020 and U+00A0.
func IsSpace(r rune) bool {
	return (r >= 0x09 && r <= 0x0D) || r == 0x20 || r == 0xA0
}

var stopWords = map[string]struct{}{}

func init() {
	for _, w := range []string{
		"a", "an", "and", "are", "as", "at", "be", "but", "by",
		"for", "if", "in", "into", "is", "it", "no", "not", "of",
		"on", "or", "such", "that", "the", "their", "then", "there", "these",
		"they", "this", "to", "was", "will", "with",
	} {
		stopWords[w] = struct{}{}
	}
}

// IsStopWord reports whether text, a folded token text, is a stop word. The
// test is made before stemming.
func IsStopWord(text string) bool {
	_, ok := stopWords[text]
	return ok
}

// Fold returns the folded form of a token: apostrophes removed and ASCII upper
// case mapped to lower case.
func Fold(token string) string {
	return string(foldInto(nil, token))
}

// foldInto appends the folded form of token to dst.
func foldInto(dst []byte, token string) []byte {
	for i := 0; i < len(token); {
		c := token[i]
		switch {
		case c >= 'A' && c <= 'Z':
			dst = append(dst, c+32)
			i++
		case c == '\'':
			i++
		case c == 0xE2 && i+2 < len(token) && token[i+1] == 0x80 && token[i+2] == 0x99: // U+2019
			i += 3
		default:
			dst = append(dst, c)
			i++
		}
	}
	return dst
}

// Term returns the index term for a folded token text.
func Term(text string) string {
	if isLowerASCII(text) {
		return porter.Stem(text)
	}
	return text
}

func isLowerASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 'a' || s[i] > 'z' {
			return false
		}
	}
	return len(s) > 0
}

type entry struct{ text, term string }

// Analyzer analyses text. It memoises folding and stemming, so reuse one
// Analyzer for a whole corpus. It is safe for concurrent use.
type Analyzer struct {
	mu    sync.Mutex
	cache map[string]entry
	buf   []byte
}

// NewAnalyzer returns an Analyzer with an empty cache.
func NewAnalyzer() *Analyzer {
	return &Analyzer{cache: make(map[string]entry)}
}

// Analyze tokenises text and returns its tokens in order; the position of a
// token is its index in the result.
//
// A token is a maximal run of token characters, optionally continued by
// apostrophes each of which sits between two token characters.
func (a *Analyzer) Analyze(text string) []Token {
	a.mu.Lock()
	defer a.mu.Unlock()
	var toks []Token
	n := len(text)
	for i := 0; i < n; {
		r, sz := decode(text, i)
		if !IsTokenChar(r) {
			i += sz
			continue
		}
		start := i
		end := scanRun(text, i)
		for end < n {
			r, sz := decode(text, end)
			if !IsApostrophe(r) {
				break
			}
			next := scanRun(text, end+sz)
			if next == end+sz {
				break
			}
			end = next
		}
		e := a.lookup(text[start:end])
		toks = append(toks, Token{Start: start, End: end, Text: e.text, Term: e.term})
		i = end
	}
	return toks
}

// Terms analyses text and returns just the terms.
func (a *Analyzer) Terms(text string) []string {
	toks := a.Analyze(text)
	terms := make([]string, len(toks))
	for i, t := range toks {
		terms[i] = t.Term
	}
	return terms
}

func (a *Analyzer) lookup(raw string) entry {
	a.buf = foldInto(a.buf[:0], raw)
	if e, ok := a.cache[string(a.buf)]; ok {
		return e
	}
	text := string(a.buf)
	e := entry{text: text, term: Term(text)}
	a.cache[text] = e
	return e
}

func decode(s string, i int) (rune, int) {
	if c := s[i]; c < utf8.RuneSelf {
		return rune(c), 1
	}
	return utf8.DecodeRuneInString(s[i:])
}

// scanRun returns the end of the run of token characters starting at i.
func scanRun(s string, i int) int {
	for i < len(s) {
		r, sz := decode(s, i)
		if !IsTokenChar(r) {
			break
		}
		i += sz
	}
	return i
}
