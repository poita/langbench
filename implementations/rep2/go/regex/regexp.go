// Package regexvm is a backtracking regular-expression engine for a small
// Perl-style subset: literals, ".", classes, \d \w \s (and complements),
// anchors "^" and "$", capturing groups, alternation and the greedy
// quantifiers * + ? {n} {n,} {n,m}.
//
// Matching follows Perl semantics exactly: start positions are tried left to
// right, alternatives in order, and quantifiers are greedy. The reported
// match is the first one found, not the longest. Captures hold the last
// value completed on the successful path.
//
// A pattern is compiled once into a flat program and executed by an
// iterative virtual machine with an explicit choice-point stack, so matching
// uses no recursion and no allocation after warm-up. A Regexp is immutable
// and safe for concurrent use; a Matcher holds scratch state and is not.
//
//	re, err := regexvm.Compile(`(\w+)@(\w+)\.com`)
//	if err != nil { ... }
//	var m regexvm.Matcher
//	m.Reset(re)
//	if m.Match([]byte("mail bob@example.com now")) {
//	    s, e, _ := m.Group(1) // 5, 8
//	}
package regexvm

// Regexp is a compiled regular expression.
type Regexp struct {
	pattern string
	insts   []inst
	classes []*charSet
	ngroups int
	nslots  int // 2*ngroups capture slots followed by loop registers

	anchored bool     // every match starts at position 0
	filter   *charSet // if non-nil, matches can only start at these bytes
}

// Compile parses and compiles a pattern.
func Compile(pattern string) (*Regexp, error) {
	tree, ngroups, err := parse(pattern)
	if err != nil {
		return nil, err
	}
	c := &compiler{ngroups: ngroups}
	c.compile(tree)
	if c.err != nil {
		return nil, c.err
	}
	c.emit(inst{op: opMatch})
	if c.err != nil {
		return nil, c.err
	}
	re := &Regexp{
		pattern: pattern,
		insts:   c.insts,
		classes: c.classes,
		ngroups: ngroups,
		nslots:  2*ngroups + c.nregs,
	}
	if tree.anchored() {
		re.anchored = true
	} else {
		var set charSet
		if !tree.first(&set) {
			all := true
			for _, in := range set {
				if !in {
					all = false
					break
				}
			}
			if !all {
				re.filter = &set
			}
		}
	}
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

// String returns the source text of the pattern.
func (re *Regexp) String() string { return re.pattern }

// NumGroups returns the number of capturing groups.
func (re *Regexp) NumGroups() int { return re.ngroups }

// MatchString reports whether the pattern matches anywhere in s.
func (re *Regexp) MatchString(s string) bool {
	var m Matcher
	m.Reset(re)
	return m.Match([]byte(s))
}

// FindSubmatchIndex returns the first match in b as
// [start, end, g1start, g1end, ...], with -1 for unset groups, or nil if
// there is no match. It allocates a fresh Matcher; for repeated use prefer
// Matcher directly.
func (re *Regexp) FindSubmatchIndex(b []byte) []int {
	var m Matcher
	m.Reset(re)
	if !m.Match(b) {
		return nil
	}
	out := make([]int, 2+2*re.ngroups)
	out[0], out[1] = m.start, m.end
	for g := 1; g <= re.ngroups; g++ {
		s, e, ok := m.Group(g)
		if !ok {
			s, e = -1, -1
		}
		out[2*g], out[2*g+1] = s, e
	}
	return out
}
