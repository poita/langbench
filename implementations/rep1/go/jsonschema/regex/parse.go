package regex

import (
	"fmt"
	"sort"
)

const maxRune = 0x10FFFF

// rng is an inclusive code point range.
type rng struct{ lo, hi rune }

type nodeKind uint8

const (
	nEmpty nodeKind = iota
	nChar
	nAny
	nClass
	nBol
	nEol
	nWordB
	nNotWordB
	nConcat
	nAlt
	nRepeat
)

// node is a regex syntax tree node.
type node struct {
	kind     nodeKind
	r        rune  // nChar
	ranges   []rng // nClass (sorted, merged)
	neg      bool  // nClass: negated
	subs     []*node
	min, max int // nRepeat; max < 0 means unbounded
}

// SyntaxError reports an invalid pattern.
type SyntaxError struct {
	Pattern string
	Msg     string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("regex: %s in %q", e.Msg, e.Pattern)
}

// maxRepeat bounds counted repetition so that expansion stays tractable.
const maxRepeat = 100000

type parser struct {
	pat  string
	src  []rune
	pos  int
	errs *SyntaxError
}

func parse(pattern string) (n *node, err error) {
	p := &parser{pat: pattern, src: []rune(pattern)}
	defer func() {
		if r := recover(); r != nil {
			if se, ok := r.(*SyntaxError); ok {
				n, err = nil, se
				return
			}
			panic(r)
		}
	}()
	n = p.alt()
	if p.pos < len(p.src) {
		p.fail("unmatched ')'")
	}
	return n, nil
}

func (p *parser) fail(msg string) {
	panic(&SyntaxError{Pattern: p.pat, Msg: msg})
}

func (p *parser) more() bool { return p.pos < len(p.src) }

func (p *parser) peek() rune { return p.src[p.pos] }

func (p *parser) eat(r rune) bool {
	if p.more() && p.src[p.pos] == r {
		p.pos++
		return true
	}
	return false
}

func (p *parser) alt() *node {
	branches := []*node{p.concat()}
	for p.eat('|') {
		branches = append(branches, p.concat())
	}
	if len(branches) == 1 {
		return branches[0]
	}
	return &node{kind: nAlt, subs: branches}
}

func (p *parser) concat() *node {
	var items []*node
	for p.more() && p.peek() != '|' && p.peek() != ')' {
		items = append(items, p.term())
	}
	switch len(items) {
	case 0:
		return &node{kind: nEmpty}
	case 1:
		return items[0]
	}
	return &node{kind: nConcat, subs: items}
}

func (p *parser) term() *node {
	atom := p.atom()
	if !p.more() {
		return atom
	}
	min, max, ok := 0, 0, true
	switch p.peek() {
	case '*':
		min, max = 0, -1
		p.pos++
	case '+':
		min, max = 1, -1
		p.pos++
	case '?':
		min, max = 0, 1
		p.pos++
	case '{':
		min, max, ok = p.braceQuantifier()
	default:
		ok = false
	}
	if !ok {
		return atom
	}
	p.eat('?') // lazy form: irrelevant for membership
	return &node{kind: nRepeat, subs: []*node{atom}, min: min, max: max}
}

// braceQuantifier parses {n}, {n,} or {n,m} at the current '{'. If the text is
// not a well-formed quantifier, nothing is consumed and ok is false.
func (p *parser) braceQuantifier() (min, max int, ok bool) {
	i := p.pos + 1
	num := func() (int, bool) {
		start, v := i, 0
		for i < len(p.src) && p.src[i] >= '0' && p.src[i] <= '9' {
			if v < maxRepeat*10 {
				v = v*10 + int(p.src[i]-'0')
			}
			i++
		}
		return v, i > start
	}
	lo, okLo := num()
	if !okLo {
		return 0, 0, false
	}
	hi := lo
	if i < len(p.src) && p.src[i] == ',' {
		i++
		var okHi bool
		hi, okHi = num()
		if !okHi {
			hi = -1
		}
	}
	if i >= len(p.src) || p.src[i] != '}' {
		return 0, 0, false
	}
	if lo > maxRepeat || hi > maxRepeat {
		p.fail("repetition count too large")
	}
	if hi >= 0 && hi < lo {
		p.fail("numbers out of order in {} quantifier")
	}
	p.pos = i + 1
	return lo, hi, true
}

func (p *parser) atom() *node {
	c := p.src[p.pos]
	p.pos++
	switch c {
	case '(':
		if p.eat('?') {
			if !p.eat(':') {
				p.fail("unsupported group syntax")
			}
		}
		n := p.alt()
		if !p.eat(')') {
			p.fail("missing ')'")
		}
		return n
	case '[':
		return p.class()
	case '.':
		return &node{kind: nAny}
	case '^':
		return &node{kind: nBol}
	case '$':
		return &node{kind: nEol}
	case '*', '+', '?':
		p.fail("nothing to repeat")
	case '\\':
		return p.escape()
	}
	return &node{kind: nChar, r: c}
}

// escape parses the escape following a backslash outside a character class.
func (p *parser) escape() *node {
	if !p.more() {
		p.fail("trailing backslash")
	}
	switch c := p.peek(); c {
	case 'b':
		p.pos++
		return &node{kind: nWordB}
	case 'B':
		p.pos++
		return &node{kind: nNotWordB}
	}
	r, set := p.classEscape(false)
	if set != nil {
		return &node{kind: nClass, ranges: set}
	}
	return &node{kind: nChar, r: r}
}

// classEscape parses an escape (the backslash is already consumed). It
// returns either a single code point or, for \d \D \w \W \s \S, a range set.
func (p *parser) classEscape(inClass bool) (rune, []rng) {
	if !p.more() {
		p.fail("trailing backslash")
	}
	c := p.src[p.pos]
	p.pos++
	switch c {
	case 'd':
		return 0, digitSet
	case 'D':
		return 0, negate(digitSet)
	case 'w':
		return 0, wordSet
	case 'W':
		return 0, negate(wordSet)
	case 's':
		return 0, spaceSet
	case 'S':
		return 0, negate(spaceSet)
	case 'n':
		return '\n', nil
	case 'r':
		return '\r', nil
	case 't':
		return '\t', nil
	case 'f':
		return '\f', nil
	case 'v':
		return '\v', nil
	case '0':
		return 0, nil
	case 'b':
		if inClass {
			return '\b', nil
		}
	case 'x':
		if r, ok := p.hexDigits(2); ok {
			return r, nil
		}
	case 'u':
		if r, ok := p.hexDigits(4); ok {
			if r >= 0xD800 && r < 0xDC00 && p.pos+1 < len(p.src) && p.src[p.pos] == '\\' && p.src[p.pos+1] == 'u' {
				save := p.pos
				p.pos += 2
				if lo, ok := p.hexDigits(4); ok && lo >= 0xDC00 && lo < 0xE000 {
					return 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00), nil
				}
				p.pos = save
			}
			return r, nil
		}
	case 'c':
		if p.more() {
			l := p.peek()
			if (l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z') {
				p.pos++
				return l % 32, nil
			}
		}
		// Annex B: "\c" not followed by a letter is a literal backslash,
		// and the 'c' is read again as an ordinary character.
		p.pos--
		return '\\', nil
	}
	// Identity escape (including unknown alphanumeric escapes).
	return c, nil
}

func (p *parser) hexDigits(n int) (rune, bool) {
	if p.pos+n > len(p.src) {
		return 0, false
	}
	var r rune
	for i := 0; i < n; i++ {
		c := p.src[p.pos+i]
		var d rune
		switch {
		case c >= '0' && c <= '9':
			d = c - '0'
		case c >= 'a' && c <= 'f':
			d = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			d = c - 'A' + 10
		default:
			return 0, false
		}
		r = r<<4 | d
	}
	p.pos += n
	return r, true
}

// class parses a character class; the '[' is already consumed.
func (p *parser) class() *node {
	n := &node{kind: nClass}
	n.neg = p.eat('^')
	var rs []rng
	for {
		if !p.more() {
			p.fail("missing ']'")
		}
		if p.eat(']') {
			break
		}
		lo, loSet := p.classAtom()
		if loSet == nil && p.more() && p.peek() == '-' && p.pos+1 < len(p.src) && p.src[p.pos+1] != ']' {
			save := p.pos
			p.pos++ // '-'
			hi, hiSet := p.classAtom()
			if hiSet == nil {
				if hi < lo {
					p.fail("range out of order in character class")
				}
				rs = append(rs, rng{lo, hi})
				continue
			}
			// "a-\d": the hyphen is literal.
			p.pos = save
		}
		if loSet != nil {
			rs = append(rs, loSet...)
		} else {
			rs = append(rs, rng{lo, lo})
		}
	}
	n.ranges = normalize(rs)
	return n
}

func (p *parser) classAtom() (rune, []rng) {
	c := p.src[p.pos]
	p.pos++
	if c == '\\' {
		return p.classEscape(true)
	}
	return c, nil
}

// normalize sorts and merges overlapping or adjacent ranges.
func normalize(rs []rng) []rng {
	if len(rs) < 2 {
		return rs
	}
	sorted := append([]rng(nil), rs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].lo < sorted[j].lo })
	out := sorted[:1]
	for _, r := range sorted[1:] {
		last := &out[len(out)-1]
		if r.lo <= last.hi+1 {
			if r.hi > last.hi {
				last.hi = r.hi
			}
			continue
		}
		out = append(out, r)
	}
	return out
}

// negate returns the complement of a normalized range set.
func negate(rs []rng) []rng {
	var out []rng
	next := rune(0)
	for _, r := range rs {
		if r.lo > next {
			out = append(out, rng{next, r.lo - 1})
		}
		next = r.hi + 1
	}
	if next <= maxRune {
		out = append(out, rng{next, maxRune})
	}
	return out
}

var (
	digitSet = []rng{{'0', '9'}}
	wordSet  = []rng{{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}}
	spaceSet = []rng{
		{0x09, 0x0D}, {0x20, 0x20}, {0xA0, 0xA0}, {0x1680, 0x1680},
		{0x2000, 0x200A}, {0x2028, 0x2029}, {0x202F, 0x202F},
		{0x205F, 0x205F}, {0x3000, 0x3000}, {0xFEFF, 0xFEFF},
	}
)
