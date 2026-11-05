// Package analysis turns text into index terms: it tokenises UTF-8 text,
// folds case and apostrophes, applies the stop-word test and Porter-stems
// ASCII words.
//
// A token is a maximal run matching TOKENCHAR+ (APOSTROPHE TOKENCHAR+)*, where
// token characters are ASCII digits and letters, Latin-1/Latin Extended
// letters (U+00C0-U+024F except U+00D7 and U+00F7), Greek and Cyrillic
// (U+0370-U+04FF). The apostrophes are U+0027 and U+2019. Folding deletes
// apostrophes and lower-cases A-Z only. The term of a token is the Porter
// stem of its folded text when that is all a-z, else the folded text itself.
package analysis

import (
	"unicode/utf8"

	"example.com/fulltext/porter"
)

// asciiToken[b] is true for the ASCII token characters.
var asciiToken [128]bool

func init() {
	for c := '0'; c <= '9'; c++ {
		asciiToken[c] = true
	}
	for c := 'a'; c <= 'z'; c++ {
		asciiToken[c] = true
		asciiToken[c-'a'+'A'] = true
	}
}

// IsTokenRune reports whether r is a token character.
func IsTokenRune(r rune) bool {
	switch {
	case r < 0x80:
		return r >= 0 && asciiToken[r]
	case r >= 0xC0 && r <= 0x24F:
		return r != 0xD7 && r != 0xF7
	case r >= 0x370 && r <= 0x4FF:
		return true
	}
	return false
}

// decode returns the code point at text[i] and its encoded size.
func decode(text []byte, i int) (rune, int) {
	if c := text[i]; c < 0x80 {
		return rune(c), 1
	}
	return utf8.DecodeRune(text[i:])
}

// apostropheLen returns the byte length of the apostrophe at text[i]
// (1 for U+0027, 3 for U+2019), or 0 if there is none.
func apostropheLen(text []byte, i int) int {
	switch {
	case text[i] == '\'':
		return 1
	case text[i] == 0xE2 && i+2 < len(text) && text[i+1] == 0x80 && text[i+2] == 0x99:
		return 3
	}
	return 0
}

// Next finds the first token starting at or after byte offset pos and returns
// its byte span [start, end). ok is false when no token remains. Scanning
// again from end yields the following token.
func Next(text []byte, pos int) (start, end int, ok bool) {
	i := pos
	for {
		if i >= len(text) {
			return 0, 0, false
		}
		r, size := decode(text, i)
		if IsTokenRune(r) {
			break
		}
		i += size
	}
	start = i
	for i < len(text) {
		r, size := decode(text, i)
		if IsTokenRune(r) {
			i += size
			continue
		}
		a := apostropheLen(text, i)
		if a == 0 || i+a >= len(text) {
			break
		}
		if r2, _ := decode(text, i+a); !IsTokenRune(r2) {
			break
		}
		i += a
	}
	return start, i, true
}

// Fold appends the folded form of the raw token to dst and returns the
// extended slice: apostrophes are deleted and A-Z become a-z.
func Fold(dst, raw []byte) []byte {
	for i := 0; i < len(raw); {
		c := raw[i]
		switch {
		case c >= 'A' && c <= 'Z':
			dst = append(dst, c+'a'-'A')
		case c == '\'':
		case c == 0xE2 && apostropheLen(raw, i) == 3:
			i += 3
			continue
		default:
			dst = append(dst, c)
		}
		i++
	}
	return dst
}

// IsASCIIWord reports whether b is non-empty and consists only of a-z.
func IsASCIIWord(b []byte) bool {
	for _, c := range b {
		if c < 'a' || c > 'z' {
			return false
		}
	}
	return len(b) > 0
}

// StemFolded converts folded token text to its term, in place: ASCII words
// are Porter-stemmed, anything else is returned unchanged.
func StemFolded(folded []byte) []byte {
	if IsASCIIWord(folded) {
		return folded[:porter.StemInPlace(folded)]
	}
	return folded
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

// IsStopWord reports whether the folded token text is one of the 33 stop
// words. Stop words are still indexed; the set only affects one-term query
// atoms.
func IsStopWord(folded string) bool {
	_, ok := stopWords[folded]
	return ok
}

// Token is an analysed token.
type Token struct {
	Start, End int    // byte span in the analysed text
	Folded     string // folded token text
	Term       string // index term
}

// Analyze tokenises text and returns every token with its folded text and
// term.
func Analyze(text string) []Token {
	b := []byte(text)
	var toks []Token
	var buf []byte
	for pos := 0; ; {
		s, e, ok := Next(b, pos)
		if !ok {
			return toks
		}
		buf = Fold(buf[:0], b[s:e])
		folded := string(buf)
		toks = append(toks, Token{Start: s, End: e, Folded: folded, Term: string(StemFolded(buf))})
		pos = e
	}
}

// Terms returns the index terms of text, in order.
func Terms(text string) []string {
	toks := Analyze(text)
	out := make([]string, len(toks))
	for i, t := range toks {
		out[i] = t.Term
	}
	return out
}
