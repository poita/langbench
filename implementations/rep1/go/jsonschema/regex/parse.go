package regex

import (
	"fmt"
	"unicode/utf8"
)

// SyntaxError reports a pattern that is not in the supported subset.
type SyntaxError struct {
	Pattern string
	Msg     string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("regex: invalid pattern %q: %s", e.Pattern, e.Msg)
}

type nodeKind uint8

const (
	nEmpty nodeKind = iota
	nRune
	nSet
	nCat
	nAlt
	nRepeat
	nAssert
)

type assertKind uint8

const (
	aBegin assertKind = iota
	aEnd
	aWordB
	aNotWordB
)

type node struct {
	kind     nodeKind
	r        rune
	set      *charset
	subs     []*node
	min, max int // repeat bounds; max < 0 means unbounded
	assert   assertKind
}

type parser struct {
	pat  string
	src  []rune
	pos  int
	errs string
}

type parseError string

func parse(pattern string) (n *node, err error) {
	p := &parser{pat: pattern}
	if !utf8.ValidString(pattern) {
		return nil, &SyntaxError{pattern, "pattern is not valid UTF-8"}
	}
	p.src = []rune(pattern)
	defer func() {
		if r := recover(); r != nil {
			if pe, ok := r.(parseError); ok {
				n, err = nil, &SyntaxError{pattern, string(pe)}
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

func (p *parser) fail(msg string) { panic(parseError(msg)) }

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
	return &node{kind: nCat, subs: items}
}

func (p *parser) term() *node {
	atom := p.atom()
	min, max, ok := p.quantifier()
	if !ok {
		return atom
	}
	p.eat('?') // lazy form: irrelevant for membership
	return &node{kind: nRepeat, subs: []*node{atom}, min: min, max: max}
}

// quantifier parses an optional quantifier. A '{' that does not begin a
// well-formed quantifier is left in place to be read as a literal.
func (p *parser) quantifier() (min, max int, ok bool) {
	if !p.more() {
		return
	}
	switch p.peek() {
	case '*':
		p.pos++
		return 0, -1, true
	case '+':
		p.pos++
		return 1, -1, true
	case '?':
		p.pos++
		return 0, 1, true
	case '{':
		save := p.pos
		min, max, ok = p.braces()
		if !ok {
			p.pos = save
		}
		return
	}
	return
}

// braces parses {n}, {n,} or {n,m} at the current '{'.
func (p *parser) braces() (min, max int, ok bool) {
	p.pos++ // {
	min, ok = p.number()
	if !ok {
		return
	}
	max = min
	if p.eat(',') {
		if p.more() && p.peek() == '}' {
			max = -1
		} else if max, ok = p.number(); !ok {
			return
		}
	}
	if !p.eat('}') {
		return 0, 0, false
	}
	if max >= 0 && max < min {
		p.fail("numbers out of order in {} quantifier")
	}
	return min, max, true
}

func (p *parser) number() (int, bool) {
	start := p.pos
	n := 0
	for p.more() && p.peek() >= '0' && p.peek() <= '9' {
		if n < 1<<24 {
			n = n*10 + int(p.peek()-'0')
		}
		p.pos++
	}
	return n, p.pos > start
}

func (p *parser) atom() *node {
	c := p.peek()
	p.pos++
	switch c {
	case '(':
		if p.eat('?') {
			if !p.eat(':') {
				p.fail("unsupported group syntax (only (?:...) is allowed)")
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
		return &node{kind: nSet, set: dotSet}
	case '^':
		return &node{kind: nAssert, assert: aBegin}
	case '$':
		return &node{kind: nAssert, assert: aEnd}
	case '*', '+', '?':
		p.fail("nothing to repeat")
	case '{':
		// Reached only when the '{' did not follow an atom: a quantifier here
		// has nothing to repeat; anything else is a literal brace.
		p.pos--
		save := p.pos
		if _, _, ok := p.braces(); ok {
			p.fail("nothing to repeat")
		}
		p.pos = save + 1
		return &node{kind: nRune, r: '{'}
	case '\\':
		return p.escape()
	}
	return &node{kind: nRune, r: c}
}

// escape parses an escape outside a character class (the backslash has been read).
func (p *parser) escape() *node {
	if !p.more() {
		p.fail("trailing backslash")
	}
	c := p.peek()
	switch c {
	case 'b':
		p.pos++
		return &node{kind: nAssert, assert: aWordB}
	case 'B':
		p.pos++
		return &node{kind: nAssert, assert: aNotWordB}
	}
	r, set := p.escapeAtom(false)
	if set != nil {
		return &node{kind: nSet, set: set}
	}
	return &node{kind: nRune, r: r}
}

// escapeAtom parses the escape after a backslash (not yet consumed), returning
// either a single code point or a class escape set.
func (p *parser) escapeAtom(inClass bool) (rune, *charset) {
	c := p.peek()
	p.pos++
	switch c {
	case 'd':
		return 0, digitSet
	case 'D':
		return 0, digitSet.negate()
	case 'w':
		return 0, wordSet
	case 'W':
		return 0, wordSet.negate()
	case 's':
		return 0, spaceSet
	case 'S':
		return 0, spaceSet.negate()
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
	case 'b':
		if inClass {
			return '\b', nil
		}
	case '0':
		return 0, nil
	case 'x':
		if r, ok := p.hex(2); ok {
			return r, nil
		}
		return 'x', nil
	case 'u':
		r, ok := p.hex(4)
		if !ok {
			return 'u', nil
		}
		if r >= 0xD800 && r < 0xDC00 && p.pos+1 < len(p.src) && p.src[p.pos] == '\\' && p.src[p.pos+1] == 'u' {
			save := p.pos
			p.pos += 2
			if r2, ok := p.hex(4); ok && r2 >= 0xDC00 && r2 < 0xE000 {
				return 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00), nil
			}
			p.pos = save
		}
		return r, nil
	case 'c':
		if p.more() {
			l := p.peek()
			if l >= 'a' && l <= 'z' || l >= 'A' && l <= 'Z' {
				p.pos++
				return l % 32, nil
			}
		}
		p.pos-- // "\c" not followed by a letter: a literal backslash
		return '\\', nil
	}
	if c >= '1' && c <= '9' {
		p.fail("backreferences are not supported")
	}
	// Identity escape: '\.' etc. mean the character itself.
	return c, nil
}

func (p *parser) hex(n int) (rune, bool) {
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

// class parses a character class (the '[' has been read).
func (p *parser) class() *node {
	negated := p.eat('^')
	set := &charset{}
	for {
		if !p.more() {
			p.fail("missing ']'")
		}
		if p.eat(']') {
			break
		}
		lo, loSet := p.classAtom()
		if loSet != nil {
			set.addSet(loSet)
			continue
		}
		// A range "lo-hi" needs a '-' that is not the last character.
		if p.pos+1 < len(p.src) && p.peek() == '-' && p.src[p.pos+1] != ']' {
			save := p.pos
			p.pos++
			hi, hiSet := p.classAtom()
			if hiSet != nil {
				// "[a-\d]": the '-' is literal.
				set.add(lo, lo)
				set.add('-', '-')
				set.addSet(hiSet)
				continue
			}
			_ = save
			if hi < lo {
				p.fail("range out of order in character class")
			}
			set.add(lo, hi)
			continue
		}
		set.add(lo, lo)
	}
	set.normalize()
	if negated {
		set = set.negate()
	}
	return &node{kind: nSet, set: set}
}

func (p *parser) classAtom() (rune, *charset) {
	c := p.peek()
	p.pos++
	if c == '\\' {
		if !p.more() {
			p.fail("trailing backslash")
		}
		return p.escapeAtom(true)
	}
	return c, nil
}
