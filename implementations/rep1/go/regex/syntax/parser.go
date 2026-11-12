package syntax

import "fmt"

// MaxRepeat is the largest count accepted in a {n,m} quantifier.
const MaxRepeat = 1000

// Error describes a syntax error in a pattern.
type Error struct {
	Pattern string // the offending pattern
	Pos     int    // byte offset at which the problem was detected
	Msg     string
}

func (e *Error) Error() string {
	return fmt.Sprintf("regex: %s at offset %d in %q", e.Msg, e.Pos, e.Pattern)
}

type parser struct {
	src     string
	pos     int
	ngroups int
}

// Parse parses pattern and returns its syntax tree together with the number
// of capturing groups it contains. Errors are returned as *Error.
func Parse(pattern string) (*Node, int, error) {
	p := &parser{src: pattern}
	n, err := p.parseAlternation()
	if err != nil {
		return nil, 0, err
	}
	if p.pos < len(p.src) { // only an unmatched ')' can stop the top level
		return nil, 0, p.errf("unmatched ')'")
	}
	return n, p.ngroups, nil
}

func (p *parser) errf(format string, args ...any) error {
	return &Error{Pattern: p.src, Pos: p.pos, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) more() bool { return p.pos < len(p.src) }

func (p *parser) peek() byte { return p.src[p.pos] }

// parseAlternation parses branch ('|' branch)* and stops before an
// unconsumed ')' or at the end of input.
func (p *parser) parseAlternation() (*Node, error) {
	var branches []*Node
	for {
		b, err := p.parseBranch()
		if err != nil {
			return nil, err
		}
		branches = append(branches, b)
		if p.more() && p.peek() == '|' {
			p.pos++
			continue
		}
		break
	}
	if len(branches) == 1 {
		return branches[0], nil
	}
	return &Node{Kind: KindAlternate, Subs: branches}, nil
}

func (p *parser) parseBranch() (*Node, error) {
	var pieces []*Node
	for p.more() && p.peek() != '|' && p.peek() != ')' {
		n, err := p.parsePiece()
		if err != nil {
			return nil, err
		}
		pieces = append(pieces, n)
	}
	switch len(pieces) {
	case 0:
		return &Node{Kind: KindEmpty}, nil
	case 1:
		return pieces[0], nil
	}
	return &Node{Kind: KindConcat, Subs: pieces}, nil
}

func (p *parser) parsePiece() (*Node, error) {
	atom, err := p.parseAtom()
	if err != nil {
		return nil, err
	}
	if !p.more() {
		return atom, nil
	}
	min, max := 0, 0
	switch p.peek() {
	case '*':
		min, max = 0, Unbounded
		p.pos++
	case '+':
		min, max = 1, Unbounded
		p.pos++
	case '?':
		min, max = 0, 1
		p.pos++
	case '{':
		min, max, err = p.parseBraces()
		if err != nil {
			return nil, err
		}
	default:
		return atom, nil
	}
	if atom.Kind == KindBol || atom.Kind == KindEol {
		return nil, p.errf("quantifier applied to an anchor")
	}
	return &Node{Kind: KindRepeat, Subs: []*Node{atom}, Min: min, Max: max}, nil
}

// parseBraces parses {n}, {n,} or {n,m}; p.pos is at the '{'.
func (p *parser) parseBraces() (min, max int, err error) {
	p.pos++ // '{'
	min, ok := p.parseInt()
	if !ok {
		return 0, 0, p.errf("expected a number after '{'")
	}
	max = min
	if p.more() && p.peek() == ',' {
		p.pos++
		if p.more() && p.peek() == '}' {
			max = Unbounded
		} else if max, ok = p.parseInt(); !ok {
			return 0, 0, p.errf("expected a number or '}' after ','")
		}
	}
	if !p.more() || p.peek() != '}' {
		return 0, 0, p.errf("expected '}'")
	}
	p.pos++
	if min > MaxRepeat || max > MaxRepeat {
		return 0, 0, p.errf("repeat count exceeds %d", MaxRepeat)
	}
	if max != Unbounded && min > max {
		return 0, 0, p.errf("invalid repeat range {%d,%d}", min, max)
	}
	return min, max, nil
}

func (p *parser) parseInt() (int, bool) {
	start, n := p.pos, 0
	for p.more() && p.peek() >= '0' && p.peek() <= '9' {
		n = n*10 + int(p.peek()-'0')
		if n > 1<<20 {
			n = 1 << 20 // saturate; rejected by the MaxRepeat check
		}
		p.pos++
	}
	return n, p.pos > start
}

func (p *parser) parseAtom() (*Node, error) {
	c := p.peek()
	switch c {
	case '(':
		p.pos++
		p.ngroups++
		g := p.ngroups
		sub, err := p.parseAlternation()
		if err != nil {
			return nil, err
		}
		if !p.more() || p.peek() != ')' {
			return nil, p.errf("missing ')'")
		}
		p.pos++
		return &Node{Kind: KindGroup, Group: g, Subs: []*Node{sub}}, nil
	case '.':
		p.pos++
		return &Node{Kind: KindAny}, nil
	case '^':
		p.pos++
		return &Node{Kind: KindBol}, nil
	case '$':
		p.pos++
		return &Node{Kind: KindEol}, nil
	case '[':
		return p.parseClass()
	case '\\':
		return p.parseEscape()
	case '*', '+', '?', '{':
		return nil, p.errf("quantifier %q has nothing to repeat", c)
	case ']', '}':
		return nil, p.errf("unexpected %q", c)
	}
	p.pos++
	return &Node{Kind: KindLiteral, Char: c}, nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// setEscape returns the set denoted by \d \D \w \W \s \S.
func setEscape(c byte) (CharSet, bool) {
	var s CharSet
	switch c {
	case 'd', 'D':
		s = digitSet()
	case 'w', 'W':
		s = wordSet()
	case 's', 'S':
		s = spaceSet()
	default:
		return s, false
	}
	if c < 'a' { // upper case: complement
		s.Negate()
	}
	return s, true
}

// parseEscape parses an escape outside a class; p.pos is at the backslash.
func (p *parser) parseEscape() (*Node, error) {
	p.pos++
	if !p.more() {
		return nil, p.errf("trailing backslash")
	}
	c := p.peek()
	if s, ok := setEscape(c); ok {
		p.pos++
		return &Node{Kind: KindClass, Set: s}, nil
	}
	if isAlnum(c) {
		return nil, p.errf("unsupported escape \\%c", c)
	}
	p.pos++
	return &Node{Kind: KindLiteral, Char: c}, nil
}

// parseClass parses a bracket expression; p.pos is at the '['.
func (p *parser) parseClass() (*Node, error) {
	p.pos++
	var set CharSet
	negate := false
	if p.more() && p.peek() == '^' {
		negate = true
		p.pos++
	}
	items := 0
	for {
		if !p.more() {
			return nil, p.errf("missing ']'")
		}
		if p.peek() == ']' && items > 0 {
			p.pos++
			break
		}
		lo, isSet, err := p.parseClassChar(&set)
		if err != nil {
			return nil, err
		}
		items++
		if isSet {
			continue
		}
		// "x-y" is a range unless the '-' is the last character of the class.
		if p.pos+1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos+1] != ']' {
			p.pos++
			hi, hiIsSet, err := p.parseClassChar(&set)
			if err != nil {
				return nil, err
			}
			if hiIsSet {
				return nil, p.errf("set escape cannot end a range")
			}
			if hi < lo {
				return nil, p.errf("invalid range %q-%q", lo, hi)
			}
			set.AddRange(lo, hi)
			continue
		}
		set.Add(lo)
	}
	if negate {
		set.Negate()
	}
	return &Node{Kind: KindClass, Set: set}, nil
}

// parseClassChar reads one class item. A set escape (\d etc.) is merged into
// set and reported with isSet; otherwise the single character is returned.
func (p *parser) parseClassChar(set *CharSet) (c byte, isSet bool, err error) {
	c = p.peek()
	p.pos++
	if c != '\\' {
		return c, false, nil
	}
	if !p.more() {
		return 0, false, p.errf("trailing backslash")
	}
	e := p.peek()
	if s, ok := setEscape(e); ok {
		p.pos++
		set.Union(&s)
		return 0, true, nil
	}
	if isAlnum(e) {
		return 0, false, p.errf("unsupported escape \\%c", e)
	}
	p.pos++
	return e, false, nil
}
