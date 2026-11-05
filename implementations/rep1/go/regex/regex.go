// Package regex is a backtracking regular-expression engine for a small,
// Perl-flavoured subset of regular-expression syntax with fully specified
// semantics: leftmost match, greedy quantifiers, ordered alternation, and
// exact capture-group positions.
//
// # Syntax
//
//	regex      := branch ( '|' branch )*
//	branch     := piece*
//	piece      := atom quantifier?
//	atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
//	quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'
//
// Escapes are \d \D \w \W \s \S and a backslash followed by any
// non-alphanumeric character (a literal). Classes are [...] and [^...] with
// single characters, ranges and set escapes. Every parenthesised group
// captures. Quantifiers are always greedy; there are no lazy quantifiers,
// back-references, or look-around. Matching is over bytes.
//
// # Semantics
//
// A pattern is searched at start positions 0, 1, ... len(subject); the first
// start at which the pattern matches determines the result. At a given start
// the first successful path in backtracking order (alternatives left to
// right, greedy repetition giving back one iteration at a time) wins. A
// group reports the span it matched the last time it completed on that path.
// An optional iteration of a repetition that matches the empty string ends
// the repetition.
//
// # Implementation
//
// A pattern is parsed into a tree, compiled into a flat program for a
// backtracking virtual machine, and run by an iterative interpreter with an
// explicit choice-point stack and an undo trail, so the matching depth is not
// limited by the Go call stack. A Regex is immutable and safe for concurrent
// use; a Matcher carries the mutable scratch state and is not.
package regex

// Regex is a compiled regular expression.
type Regex struct {
	pattern string
	prog    []inst
	classes []charset
	ngroups int
	nslots  int // capture slots followed by loop registers
	ncaps   int // 2*(ngroups+1): the slots reset before every start position

	anchored bool     // every match begins with ^: only start 0 is tried
	filter   bool     // skip start positions whose byte is not in first
	first    *charset // bytes a non-empty match can start with
}

// Compile parses and compiles a pattern. It returns a *SyntaxError for an
// invalid pattern and a *LimitError if the pattern expands to too large a
// program.
func Compile(pattern string) (*Regex, error) {
	tree, ngroups, err := parse(pattern)
	if err != nil {
		return nil, err
	}
	c := &compiler{nslots: 2 * (ngroups + 1), classID: map[*charset]int32{}}
	c.gen(tree)
	c.emit(inst{op: opMatch})
	if c.limit {
		return nil, &LimitError{Pattern: pattern, Msg: "compiled program too large"}
	}
	re := &Regex{
		pattern: pattern,
		prog:    c.prog,
		classes: c.classes,
		ngroups: ngroups,
		ncaps:   c.nslots,
		nslots:  c.nslots + c.nregs,
	}
	re.anchored = anchoredAtStart(tree)
	var first charset
	nullable := firstSet(tree, &first)
	if !nullable && !first.full() {
		re.filter = true
		re.first = &first
	}
	return re, nil
}

// MustCompile is like Compile but panics if the pattern is invalid.
func MustCompile(pattern string) *Regex {
	re, err := Compile(pattern)
	if err != nil {
		panic(err)
	}
	return re
}

// String returns the pattern the Regex was compiled from.
func (re *Regex) String() string { return re.pattern }

// NumGroups returns the number of capturing groups in the pattern.
func (re *Regex) NumGroups() int { return re.ngroups }

// MatchString reports whether the pattern matches anywhere in s.
func (re *Regex) MatchString(s string) bool {
	return NewMatcher(re).Find([]byte(s))
}

// FindStringSubmatchIndex returns the span of the first match in s and of its
// capture groups as [start, end, g1start, g1end, ...], using -1 for groups
// that did not participate. It returns nil if there is no match.
func (re *Regex) FindStringSubmatchIndex(s string) []int {
	m := NewMatcher(re)
	if !m.Find([]byte(s)) {
		return nil
	}
	out := make([]int, 2*(re.ngroups+1))
	out[0], out[1] = m.Span()
	for g := 1; g <= re.ngroups; g++ {
		if gs, ge, ok := m.Group(g); ok {
			out[2*g], out[2*g+1] = gs, ge
		} else {
			out[2*g], out[2*g+1] = -1, -1
		}
	}
	return out
}
