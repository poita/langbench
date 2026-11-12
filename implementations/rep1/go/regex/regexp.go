// Package regexbt is a small backtracking regular-expression engine with
// Perl-style semantics: leftmost match, greedy quantifiers and ordered
// alternation, reporting the position of every capture group.
//
// The supported syntax is a deliberately small subset: literals, '.', '^',
// '$', character classes, the escapes \d \D \w \W \s \S, capturing groups,
// '|', and the greedy quantifiers * + ? {n} {n,} {n,m}. See the README for
// the full grammar and the precise matching rules.
//
// Matching is by depth-first backtracking, so pathological patterns such as
// (a*)*b can take exponential time on adversarial subjects. Backtracking
// state lives on an explicit heap-allocated stack, so long subjects do not
// overflow the goroutine stack.
//
// A compiled Regexp is safe for concurrent use by multiple goroutines.
package regexbt

import (
	"sync"

	"example.com/regexbt/syntax"
)

// Span is a half-open byte range [Start, End) of the subject. A group that
// did not participate in the match has Start == End == -1.
type Span struct {
	Start, End int
}

// IsSet reports whether the span refers to matched text.
func (s Span) IsSet() bool { return s.Start >= 0 }

// Match describes a successful match.
type Match struct {
	Start, End int    // extent of the whole match
	Groups     []Span // Groups[i] is capture group i+1
}

// Regexp is a compiled regular expression.
type Regexp struct {
	pattern  string
	prog     *prog
	first    syntax.CharSet // bytes that can begin a match
	nullable bool           // a match may be empty (or begin with an assertion)
	anchored bool           // can only match at offset 0
	pool     sync.Pool      // of *machine
}

// Compile parses and compiles pattern. Syntax errors are reported as
// *syntax.Error.
func Compile(pattern string) (*Regexp, error) {
	tree, ngroups, err := syntax.Parse(pattern)
	if err != nil {
		return nil, err
	}
	p, err := compile(tree, ngroups)
	if err != nil {
		return nil, err
	}
	re := &Regexp{pattern: pattern, prog: p}
	re.first, re.nullable = firstSet(tree)
	re.anchored = startsWithBol(tree)
	re.pool.New = func() any { return newMachine(p.nregs) }
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
func (re *Regexp) String() string { return re.pattern }

// NumGroups returns the number of capturing groups in the pattern.
func (re *Regexp) NumGroups() int { return re.prog.ngroup }

// Find returns the first match of the pattern in s, if any.
func (re *Regexp) Find(s string) (Match, bool) {
	var m Match
	ok := re.FindInto(s, &m)
	return m, ok
}

// MatchString reports whether the pattern matches anywhere in s.
func (re *Regexp) MatchString(s string) bool {
	var m Match
	return re.FindInto(s, &m)
}

// FindInto is like Find but stores the result in m, reusing m.Groups when it
// has enough capacity. It reports whether a match was found; m is left
// unspecified when it was not.
func (re *Regexp) FindInto(s string, m *Match) bool {
	mach := re.pool.Get().(*machine)
	defer re.pool.Put(mach)

	last := len(s)
	if re.anchored {
		last = 0
	}
	for start := 0; start <= last; start++ {
		if !re.nullable && (start == len(s) || !re.first.Has(s[start])) {
			continue
		}
		end, ok := mach.match(re.prog, s, start)
		if !ok {
			continue
		}
		m.Start, m.End = start, end
		ng := re.prog.ngroup
		if cap(m.Groups) >= ng {
			m.Groups = m.Groups[:ng]
		} else {
			m.Groups = make([]Span, ng)
		}
		for g := 1; g <= ng; g++ {
			m.Groups[g-1] = Span{mach.regs[2*g], mach.regs[2*g+1]}
		}
		mach.unwind(0)
		return true
	}
	return false
}
