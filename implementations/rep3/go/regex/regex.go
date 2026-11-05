// Package regex is a small backtracking regular-expression engine with
// Perl-style semantics: leftmost match, greedy quantifiers, ordered
// alternation, and capture groups reported as positions.
//
// Patterns are compiled once into a flat program for a backtracking virtual
// machine (see package regex/prog). Matching uses an explicit choice-point
// stack and an undo trail, so recursion depth does not grow with the subject
// and a Matcher allocates nothing per match once its buffers have grown.
//
// Supported syntax: literals, '.', '^', '$', character classes ([a-z], [^x],
// \d \D \w \W \s \S inside and outside classes), escaped punctuation,
// capturing groups, '|', and the greedy quantifiers * + ? {n} {n,} {n,m}.
// There are no non-capturing groups, lazy quantifiers, lookaround or
// backreferences.
//
// A Regexp is immutable and safe for concurrent use. A Matcher holds scratch
// state and is not.
package regex

import (
	"regex/prog"
	"regex/syntax"
)

// Regexp is a compiled regular expression.
type Regexp struct {
	pattern string
	prog    *prog.Program
}

// Compile parses and compiles pattern.
func Compile(pattern string) (*Regexp, error) {
	tree, err := syntax.Parse(pattern)
	if err != nil {
		return nil, err
	}
	p, err := prog.Compile(tree)
	if err != nil {
		return nil, err
	}
	return &Regexp{pattern: pattern, prog: p}, nil
}

// MustCompile is like Compile but panics if the pattern is invalid.
func MustCompile(pattern string) *Regexp {
	re, err := Compile(pattern)
	if err != nil {
		panic(err)
	}
	return re
}

// String returns the source text of the pattern.
func (re *Regexp) String() string { return re.pattern }

// NumGroups returns the number of capture groups in the pattern.
func (re *Regexp) NumGroups() int { return re.prog.NumGroups }

// Program returns the compiled program, mainly for inspection and debugging.
func (re *Regexp) Program() *prog.Program { return re.prog }

// MatchString reports whether s contains a match.
func (re *Regexp) MatchString(s string) bool {
	return re.NewMatcher().Find([]byte(s))
}

// FindSubmatchIndex returns the first match in b as a slice of 2*(1+n)
// offsets: the match start and end followed by the start and end of each of
// the n groups, with -1 for both when a group did not participate. It
// returns nil when there is no match.
func (re *Regexp) FindSubmatchIndex(b []byte) []int {
	m := re.NewMatcher()
	if !m.Find(b) {
		return nil
	}
	out := make([]int, 0, 2+2*re.prog.NumGroups)
	out = append(out, m.Start(), m.End())
	for g := 1; g <= re.prog.NumGroups; g++ {
		s, e, _ := m.Group(g)
		out = append(out, s, e)
	}
	return out
}

// FindStringSubmatchIndex is like FindSubmatchIndex for a string subject.
func (re *Regexp) FindStringSubmatchIndex(s string) []int {
	return re.FindSubmatchIndex([]byte(s))
}

// Matcher runs a Regexp against subjects, reusing its working storage
// between calls. Use one Matcher per goroutine.
type Matcher struct {
	re         *Regexp
	caps       []int32 // capture slots followed by loop registers; -1 = unset
	stack      []choice
	trail      []undo
	start, end int
}

// NewMatcher returns a Matcher for re.
func (re *Regexp) NewMatcher() *Matcher {
	p := re.prog
	return &Matcher{re: re, caps: make([]int32, p.NumCaps+p.NumRegs)}
}

// Start returns the start offset of the last successful match.
func (m *Matcher) Start() int { return m.start }

// End returns the exclusive end offset of the last successful match.
func (m *Matcher) End() int { return m.end }

// Group returns the offsets of capture group g (1-based) in the last
// successful match. ok is false, and both offsets are -1, when the group is
// unset or g is out of range.
func (m *Matcher) Group(g int) (start, end int, ok bool) {
	if g < 1 || g > m.re.prog.NumGroups || m.caps[2*(g-1)] < 0 {
		return -1, -1, false
	}
	return int(m.caps[2*(g-1)]), int(m.caps[2*(g-1)+1]), true
}
