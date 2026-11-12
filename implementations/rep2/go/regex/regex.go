// Package regex is a backtracking regular-expression engine for a small
// Perl-style dialect, with leftmost, greedy, ordered-choice semantics.
//
// # Syntax
//
//	literal        any byte except \ . [ ] ( ) | * + ? { } ^ $
//	.              any single byte
//	^  $           start / end of the subject (zero width)
//	[a-z_] [^0-9]  character classes with ranges, negation and \d \w \s
//	\d \w \s       digit, word and space classes; \D \W \S are complements
//	\.  \\  \-     backslash followed by punctuation matches that character
//	(re)           capturing group, numbered by the position of its '('
//	a|b            alternation (lowest precedence); branches may be empty
//	* + ? {n} {n,} {n,m}   greedy quantifiers (counts up to 1000)
//
// # Semantics
//
// The matcher explores alternatives depth-first in the order written. The
// first successful path wins, even when another path would match more text;
// quantifiers are greedy and give back one iteration at a time. An optional
// iteration that consumes nothing ends its loop. A group reports the span it
// matched the last time it was completed along the successful path, and is
// unset if it never completed. Searching tries start offsets 0, 1, ... in
// order and reports the first that matches.
//
// Matching is by bytes: the subject is treated as a sequence of 8-bit
// characters. Because it backtracks, matching time is exponential in the worst
// case.
package regex

import (
	"sync"

	"example.com/regex/syntax"
)

// Regexp is a compiled regular expression. It is safe for concurrent use by
// multiple goroutines.
type Regexp struct {
	expr   string
	prog   *program
	info   searchInfo
	groups int
	pool   sync.Pool // of *machine
}

// Compile parses and compiles a pattern. Syntax errors are returned as
// *syntax.Error.
func Compile(pattern string) (*Regexp, error) {
	root, groups, err := syntax.Parse(pattern)
	if err != nil {
		return nil, err
	}
	prog, err := compile(root, groups)
	if err != nil {
		return nil, err
	}
	re := &Regexp{expr: pattern, prog: prog, info: analyze(root), groups: groups}
	re.pool.New = func() any { return newMachine(prog) }
	return re, nil
}

// MustCompile is like Compile but panics if the pattern is invalid.
func MustCompile(pattern string) *Regexp {
	re, err := Compile(pattern)
	if err != nil {
		panic(err)
	}
	return re
}

// String returns the pattern the Regexp was compiled from.
func (re *Regexp) String() string { return re.expr }

// NumGroups returns the number of capturing groups in the pattern.
func (re *Regexp) NumGroups() int { return re.groups }

// Span is a half-open range [Start, End) of subject offsets.
type Span struct{ Start, End int }

// Match describes the first match of a pattern in a subject.
type Match struct {
	Span          // the whole match
	Groups []Span // Groups[i] is capture group i+1; Start == End == -1 if unset
}

// IsSet reports whether the span refers to text, i.e. a group that took part
// in the match.
func (s Span) IsSet() bool { return s.Start >= 0 }

// Find returns the first match in s, or nil if the pattern does not match.
func (re *Regexp) Find(s string) *Match {
	loc, ok := re.FindIndex(s, nil)
	if !ok {
		return nil
	}
	return newMatch(loc)
}

// FindBytes is like Find for a byte slice.
func (re *Regexp) FindBytes(b []byte) *Match {
	loc, ok := re.FindIndexBytes(b, nil)
	if !ok {
		return nil
	}
	return newMatch(loc)
}

// MatchString reports whether the pattern matches anywhere in s.
func (re *Regexp) MatchString(s string) bool {
	_, ok := re.FindIndex(s, nil)
	return ok
}

func newMatch(loc []int) *Match {
	m := &Match{Span: Span{loc[0], loc[1]}, Groups: make([]Span, len(loc)/2-1)}
	for g := range m.Groups {
		m.Groups[g] = Span{loc[2+2*g], loc[3+2*g]}
	}
	return m
}

// FindIndex is the allocation-free form of Find. On success it returns
// dst[:0] extended with 2*(NumGroups()+1) offsets: the match start and end,
// then the start and end of each group in order, with -1 for both offsets of
// a group that is unset. If the pattern does not match, ok is false.
func (re *Regexp) FindIndex(s string, dst []int) (loc []int, ok bool) {
	return find(re, s, dst)
}

// FindIndexBytes is like FindIndex for a byte slice.
func (re *Regexp) FindIndexBytes(b []byte, dst []int) (loc []int, ok bool) {
	return find(re, b, dst)
}

func find[T ~string | ~[]byte](re *Regexp, s T, dst []int) ([]int, bool) {
	m := re.pool.Get().(*machine)
	defer re.pool.Put(m)
	info := &re.info
	for start := 0; start <= len(s); start++ {
		if !info.nullable {
			// A match must consume a byte, and it must be one that can begin it.
			if start == len(s) {
				break
			}
			if !info.first.Has(s[start]) {
				if info.anchored {
					break
				}
				continue
			}
		}
		end, ok := run(m, re.prog, s, start)
		if ok {
			dst = append(dst[:0], start, end)
			dst = append(dst, m.slots[:2*re.groups]...)
			m.reset()
			return dst, true
		}
		if info.anchored {
			break
		}
	}
	return nil, false
}
