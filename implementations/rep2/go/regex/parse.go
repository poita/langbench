package regexvm

import "fmt"

// maxGroups bounds the number of capturing groups in a pattern.
const maxGroups = 1000

// SyntaxError describes an invalid pattern.
type SyntaxError struct {
	Pattern string // the offending pattern
	Pos     int    // byte offset of the problem
	Msg     string // description
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("regexvm: invalid pattern %q at offset %d: %s", e.Pattern, e.Pos, e.Msg)
}

type parser struct {
	src     string
	pos     int
	ngroups int
}

// parse turns a pattern into a syntax tree and returns the group count.
func parse(src string) (*node, int, error) {
	p := &parser{src: src}
	n, err := p.parseAlt()
	if err != nil {
		return nil, 0, err
	}
	if p.pos < len(p.src) {
		return nil, 0, p.errf("unmatched ')'")
	}
	return n, p.ngroups, nil
}

func (p *parser) errf(format string, args ...any) error {
	return &SyntaxError{Pattern: p.src, Pos: p.pos, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) more() bool { return p.pos < len(p.src) }

func (p *parser) parseAlt() (*node, error) {
	var branches []*node
	for {
		b, err := p.parseBranch()
		if err != nil {
			return nil, err
		}
		branches = append(branches, b)
		if p.more() && p.src[p.pos] == '|' {
			p.pos++
			continue
		}
		break
	}
	if len(branches) == 1 {
		return branches[0], nil
	}
	return &node{kind: nAlt, subs: branches}, nil
}

func (p *parser) parseBranch() (*node, error) {
	var items []*node
	for p.more() && p.src[p.pos] != '|' && p.src[p.pos] != ')' {
		it, err := p.parsePiece()
		if err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	if len(items) == 1 {
		return items[0], nil
	}
	return &node{kind: nSeq, subs: items}, nil
}

func (p *parser) parsePiece() (*node, error) {
	atom, err := p.parseAtom()
	if err != nil {
		return nil, err
	}
	if !p.more() {
		return atom, nil
	}
	min, max := 0, 0
	switch p.src[p.pos] {
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
		min, max, err = p.parseBraces()
		if err != nil {
			return nil, err
		}
	default:
		return atom, nil
	}
	if atom.kind == nBol || atom.kind == nEol {
		return nil, p.errf("quantifier after anchor")
	}
	if p.more() {
		switch p.src[p.pos] {
		case '*', '+', '?', '{':
			return nil, p.errf("quantifier follows quantifier")
		}
	}
	return &node{kind: nRep, subs: []*node{atom}, min: min, max: max}, nil
}

// parseBraces parses {n}, {n,} or {n,m}; the cursor is on the '{'.
func (p *parser) parseBraces() (min, max int, err error) {
	p.pos++ // '{'
	min, ok := p.parseInt()
	if !ok {
		return 0, 0, p.errf("expected number in quantifier")
	}
	max = min
	if p.more() && p.src[p.pos] == ',' {
		p.pos++
		if m, ok := p.parseInt(); ok {
			max = m
		} else {
			max = -1
		}
	}
	if !p.more() || p.src[p.pos] != '}' {
		return 0, 0, p.errf("expected '}' in quantifier")
	}
	p.pos++
	if max >= 0 && max < min {
		return 0, 0, p.errf("quantifier minimum exceeds maximum")
	}
	return min, max, nil
}

func (p *parser) parseInt() (int, bool) {
	start, v := p.pos, 0
	for p.more() && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		v = v*10 + int(p.src[p.pos]-'0')
		if v > 1<<20 {
			v = 1 << 20
		}
		p.pos++
	}
	return v, p.pos > start
}

func (p *parser) parseAtom() (*node, error) {
	c := p.src[p.pos]
	switch c {
	case '(':
		p.pos++
		if p.ngroups >= maxGroups {
			return nil, p.errf("too many groups")
		}
		p.ngroups++
		g := p.ngroups
		body, err := p.parseAlt()
		if err != nil {
			return nil, err
		}
		if !p.more() || p.src[p.pos] != ')' {
			return nil, p.errf("missing ')'")
		}
		p.pos++
		return &node{kind: nGroup, subs: []*node{body}, group: g}, nil
	case '.':
		p.pos++
		return &node{kind: nAny}, nil
	case '^':
		p.pos++
		return &node{kind: nBol}, nil
	case '$':
		p.pos++
		return &node{kind: nEol}, nil
	case '[':
		return p.parseClass()
	case '\\':
		return p.parseEscape()
	case '*', '+', '?', '{':
		return nil, p.errf("nothing to repeat")
	case ']', '}':
		return nil, p.errf("unexpected %q", c)
	}
	p.pos++
	return &node{kind: nLit, ch: c}, nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// setEscape returns the set for \d \D \w \W \s \S, or nil if c is not one.
func setEscape(c byte) *charSet {
	var s charSet
	switch c {
	case 'd', 'D':
		addRange(&s, '0', '9')
	case 'w', 'W':
		addRange(&s, '0', '9')
		addRange(&s, 'a', 'z')
		addRange(&s, 'A', 'Z')
		s['_'] = true
	case 's', 'S':
		for _, ch := range " \t\n\r\f\v" {
			s[ch] = true
		}
	default:
		return nil
	}
	if c == 'D' || c == 'W' || c == 'S' {
		negate(&s)
	}
	return &s
}

func addRange(s *charSet, lo, hi byte) {
	for c := int(lo); c <= int(hi); c++ {
		s[c] = true
	}
}

func negate(s *charSet) {
	for i := range s {
		s[i] = !s[i]
	}
}

func (p *parser) parseEscape() (*node, error) {
	p.pos++ // '\'
	if !p.more() {
		return nil, p.errf("trailing backslash")
	}
	c := p.src[p.pos]
	if s := setEscape(c); s != nil {
		p.pos++
		return &node{kind: nClass, set: s}, nil
	}
	if isAlnum(c) {
		return nil, p.errf("unsupported escape \\%c", c)
	}
	p.pos++
	return &node{kind: nLit, ch: c}, nil
}

// parseClass parses a bracketed class; the cursor is on the '['.
func (p *parser) parseClass() (*node, error) {
	p.pos++ // '['
	var set charSet
	neg := false
	if p.more() && p.src[p.pos] == '^' {
		neg = true
		p.pos++
	}
	items := 0
	for {
		if !p.more() {
			return nil, p.errf("missing ']'")
		}
		if p.src[p.pos] == ']' && items > 0 {
			p.pos++
			break
		}
		lo, es, err := p.classItem()
		if err != nil {
			return nil, err
		}
		items++
		if es != nil {
			for i, in := range es {
				if in {
					set[i] = true
				}
			}
			continue
		}
		// range x-y, unless the '-' is the last character before ']'
		if p.pos+1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos+1] != ']' {
			p.pos++
			hi, es2, err := p.classItem()
			if err != nil {
				return nil, err
			}
			if es2 != nil || hi < lo {
				return nil, p.errf("invalid range")
			}
			addRange(&set, lo, hi)
			continue
		}
		set[lo] = true
	}
	if neg {
		negate(&set)
	}
	return &node{kind: nClass, set: &set}, nil
}

// classItem parses one class item: a single character (returned as ch) or a
// set escape (returned as set).
func (p *parser) classItem() (ch byte, set *charSet, err error) {
	c := p.src[p.pos]
	p.pos++
	if c != '\\' {
		return c, nil, nil
	}
	if !p.more() {
		return 0, nil, p.errf("trailing backslash")
	}
	e := p.src[p.pos]
	if s := setEscape(e); s != nil {
		p.pos++
		return 0, s, nil
	}
	if isAlnum(e) {
		return 0, nil, p.errf("unsupported escape \\%c", e)
	}
	p.pos++
	return e, nil, nil
}
