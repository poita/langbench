package regex

import "strconv"

// maxCount is the largest repetition bound accepted in {n,m}.
const maxCount = 1000

type parser struct {
	src     string
	pos     int
	ngroups int
}

// parse turns a pattern into a syntax tree and returns the number of
// capturing groups.
func parse(src string) (*node, int, error) {
	p := &parser{src: src}
	n, err := p.parseAlt()
	if err != nil {
		return nil, 0, err
	}
	if p.pos < len(p.src) { // only an unmatched ')' stops parseAlt early
		return nil, 0, p.errf("unmatched )")
	}
	return n, p.ngroups, nil
}

func (p *parser) errf(msg string) error {
	return &SyntaxError{Pattern: p.src, Offset: p.pos, Msg: msg}
}

func (p *parser) more() bool { return p.pos < len(p.src) }

// parseAlt parses branch ('|' branch)*.
func (p *parser) parseAlt() (*node, error) {
	var branches []*node
	for {
		b, err := p.parseSeq()
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

// parseSeq parses a (possibly empty) concatenation of pieces.
func (p *parser) parseSeq() (*node, error) {
	seq := &node{kind: nSeq}
	for p.more() && p.src[p.pos] != '|' && p.src[p.pos] != ')' {
		piece, err := p.parsePiece()
		if err != nil {
			return nil, err
		}
		seq.subs = append(seq.subs, piece)
	}
	return seq, nil
}

func isQuantStart(c byte) bool { return c == '*' || c == '+' || c == '?' || c == '{' }

func (p *parser) parsePiece() (*node, error) {
	atom, err := p.parseAtom()
	if err != nil {
		return nil, err
	}
	if !p.more() || !isQuantStart(p.src[p.pos]) {
		return atom, nil
	}
	if atom.kind == nBol || atom.kind == nEol {
		return nil, p.errf("quantifier after anchor")
	}
	min, max, err := p.parseQuantifier()
	if err != nil {
		return nil, err
	}
	if p.more() && isQuantStart(p.src[p.pos]) {
		return nil, p.errf("quantifier after quantifier")
	}
	return &node{kind: nRep, subs: []*node{atom}, min: min, max: max}, nil
}

func (p *parser) parseQuantifier() (min, max int, err error) {
	c := p.src[p.pos]
	p.pos++
	switch c {
	case '*':
		return 0, -1, nil
	case '+':
		return 1, -1, nil
	case '?':
		return 0, 1, nil
	}
	// '{' n ['}' | ',' [m] '}']
	min, err = p.parseNumber()
	if err != nil {
		return 0, 0, err
	}
	if p.more() && p.src[p.pos] == '}' {
		p.pos++
		return min, min, nil
	}
	if !p.more() || p.src[p.pos] != ',' {
		return 0, 0, p.errf("malformed counted quantifier")
	}
	p.pos++
	if p.more() && p.src[p.pos] == '}' {
		p.pos++
		return min, -1, nil
	}
	max, err = p.parseNumber()
	if err != nil {
		return 0, 0, err
	}
	if !p.more() || p.src[p.pos] != '}' {
		return 0, 0, p.errf("malformed counted quantifier")
	}
	p.pos++
	if max < min {
		return 0, 0, p.errf("repetition bounds out of order")
	}
	return min, max, nil
}

func (p *parser) parseNumber() (int, error) {
	start := p.pos
	for p.more() && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		p.pos++
	}
	if start == p.pos {
		return 0, p.errf("expected number in counted quantifier")
	}
	if p.pos-start > 4 {
		return 0, p.errf("repetition count too large")
	}
	v, _ := strconv.Atoi(p.src[start:p.pos])
	if v > maxCount {
		return 0, p.errf("repetition count too large")
	}
	return v, nil
}

func (p *parser) parseAtom() (*node, error) {
	c := p.src[p.pos]
	switch c {
	case '(':
		p.pos++
		p.ngroups++
		g := p.ngroups
		body, err := p.parseAlt()
		if err != nil {
			return nil, err
		}
		if !p.more() || p.src[p.pos] != ')' {
			return nil, p.errf("missing )")
		}
		p.pos++
		return &node{kind: nGroup, group: g, subs: []*node{body}}, nil
	case '[':
		return p.parseClass()
	case '\\':
		return p.parseEscape()
	case '.':
		p.pos++
		return &node{kind: nAny}, nil
	case '^':
		p.pos++
		return &node{kind: nBol}, nil
	case '$':
		p.pos++
		return &node{kind: nEol}, nil
	case '*', '+', '?', '{':
		return nil, p.errf("nothing to repeat")
	case ']', '}':
		return nil, p.errf("unexpected " + string(c))
	}
	p.pos++
	return &node{kind: nLit, ch: c}, nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// parseEscape parses an escape outside a class.
func (p *parser) parseEscape() (*node, error) {
	p.pos++ // backslash
	if !p.more() {
		return nil, p.errf("trailing backslash")
	}
	c := p.src[p.pos]
	if set := setEscape(c); set != nil {
		p.pos++
		return &node{kind: nClass, set: set}, nil
	}
	if isAlnum(c) {
		return nil, p.errf("unsupported escape \\" + string(c))
	}
	p.pos++
	return &node{kind: nLit, ch: c}, nil
}

// classAtom parses one class item that is a single character (a plain
// character or an escaped punctuation character) or a set escape. For a
// set escape it returns the set; otherwise the character.
func (p *parser) classAtom() (c byte, set *charset, err error) {
	c = p.src[p.pos]
	switch c {
	case ']':
		return 0, nil, p.errf("unexpected ] in class")
	case '\\':
		p.pos++
		if !p.more() {
			return 0, nil, p.errf("trailing backslash")
		}
		e := p.src[p.pos]
		if s := setEscape(e); s != nil {
			p.pos++
			return 0, s, nil
		}
		if isAlnum(e) {
			return 0, nil, p.errf("unsupported escape \\" + string(e))
		}
		p.pos++
		return e, nil, nil
	}
	p.pos++
	return c, nil, nil
}

func (p *parser) parseClass() (*node, error) {
	p.pos++ // [
	var set charset
	negate := false
	if p.more() && p.src[p.pos] == '^' {
		negate = true
		p.pos++
	}
	items := 0
	for {
		if !p.more() {
			return nil, p.errf("missing ]")
		}
		if p.src[p.pos] == ']' && items > 0 {
			p.pos++
			break
		}
		lo, s, err := p.classAtom()
		if err != nil {
			return nil, err
		}
		items++
		if s != nil {
			set.union(s)
			continue
		}
		// A '-' between two single characters is a range operator; before
		// ']' it is a literal and is handled on the next iteration.
		if p.pos+1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos+1] != ']' {
			p.pos++
			hi, hs, err := p.classAtom()
			if err != nil {
				return nil, err
			}
			if hs != nil {
				return nil, p.errf("set escape as range end")
			}
			if hi < lo {
				return nil, p.errf("range out of order")
			}
			set.addRange(lo, hi)
			continue
		}
		set.add(lo)
	}
	if negate {
		set.negate()
	}
	return &node{kind: nClass, set: &set}, nil
}
