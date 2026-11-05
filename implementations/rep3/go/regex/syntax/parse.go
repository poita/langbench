package syntax

import "fmt"

// MaxRepeat is the largest count accepted in a {n,m} quantifier.
const MaxRepeat = 1000

// Error describes a syntax error in a pattern.
type Error struct {
	Pattern string
	Pos     int // byte offset of the error in Pattern
	Msg     string
}

func (e *Error) Error() string {
	return fmt.Sprintf("regex: error parsing %q at offset %d: %s", e.Pattern, e.Pos, e.Msg)
}

type parser struct {
	src    string
	pos    int
	groups int
}

// Parse parses pattern into a syntax tree.
func Parse(pattern string) (*Tree, error) {
	p := &parser{src: pattern}
	root, err := p.parseAlt()
	if err != nil {
		return nil, err
	}
	if p.pos < len(p.src) {
		// parseAlt only stops early at an unmatched ')'.
		return nil, p.errf("unmatched )")
	}
	return &Tree{Root: root, NumGroups: p.groups}, nil
}

func (p *parser) errf(format string, args ...any) error {
	return &Error{Pattern: p.src, Pos: p.pos, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) more() bool { return p.pos < len(p.src) }

func (p *parser) peek() byte { return p.src[p.pos] }

// parseAlt parses branch ('|' branch)*.
func (p *parser) parseAlt() (*Node, error) {
	var branches []*Node
	for {
		b, err := p.parseSeq()
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
	return &Node{Kind: KindAlt, Subs: branches}, nil
}

// parseSeq parses piece*, stopping at '|', ')' or the end of the pattern.
func (p *parser) parseSeq() (*Node, error) {
	var items []*Node
	for p.more() {
		c := p.peek()
		if c == '|' || c == ')' {
			break
		}
		atom, err := p.parseAtom()
		if err != nil {
			return nil, err
		}
		if p.more() {
			switch p.peek() {
			case '*', '+', '?', '{':
				if atom.Kind == KindBOL || atom.Kind == KindEOL {
					return nil, p.errf("quantifier applied to an anchor")
				}
				atom, err = p.parseQuantifier(atom)
				if err != nil {
					return nil, err
				}
			}
		}
		items = append(items, atom)
	}
	if len(items) == 1 {
		return items[0], nil
	}
	return &Node{Kind: KindSeq, Subs: items}, nil
}

func (p *parser) parseAtom() (*Node, error) {
	c := p.peek()
	switch c {
	case '.':
		p.pos++
		return &Node{Kind: KindAny}, nil
	case '^':
		p.pos++
		return &Node{Kind: KindBOL}, nil
	case '$':
		p.pos++
		return &Node{Kind: KindEOL}, nil
	case '(':
		p.pos++
		p.groups++
		idx := p.groups
		body, err := p.parseAlt()
		if err != nil {
			return nil, err
		}
		if !p.more() || p.peek() != ')' {
			return nil, p.errf("missing closing )")
		}
		p.pos++
		return &Node{Kind: KindGroup, Index: idx, Subs: []*Node{body}}, nil
	case '[':
		return p.parseClass()
	case '\\':
		return p.parseEscape()
	case '*', '+', '?', '{':
		return nil, p.errf("missing argument to repetition operator %q", c)
	case ']', '}':
		return nil, p.errf("unexpected %q", c)
	}
	p.pos++
	return &Node{Kind: KindLiteral, Char: c}, nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func (p *parser) parseEscape() (*Node, error) {
	p.pos++ // backslash
	if !p.more() {
		return nil, p.errf("trailing backslash")
	}
	c := p.peek()
	if set, ok := escapeSet(c); ok {
		p.pos++
		return &Node{Kind: KindClass, Set: &set}, nil
	}
	if isAlnum(c) {
		return nil, p.errf("unsupported escape \\%c", c)
	}
	p.pos++
	return &Node{Kind: KindLiteral, Char: c}, nil
}

// parseClass parses '[' '^'? item+ ']'.
func (p *parser) parseClass() (*Node, error) {
	p.pos++ // '['
	var set CharSet
	negate := false
	if p.more() && p.peek() == '^' {
		negate = true
		p.pos++
	}
	items := 0
	for {
		if !p.more() {
			return nil, p.errf("missing closing ]")
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
		// A '-' that is followed by something other than ']' is a range operator.
		if p.pos+1 < len(p.src) && p.peek() == '-' && p.src[p.pos+1] != ']' {
			p.pos++
			hi, hiIsSet, err := p.parseClassChar(nil)
			if err != nil {
				return nil, err
			}
			if hiIsSet || hi < lo {
				return nil, p.errf("invalid character range")
			}
			set.AddRange(lo, hi)
		} else {
			set.Add(lo)
		}
	}
	if negate {
		set.Negate()
	}
	return &Node{Kind: KindClass, Set: &set}, nil
}

// parseClassChar parses one class item head: a plain character, an escaped
// character, or a set escape. A set escape is added to into (when non-nil)
// and reported with isSet = true.
func (p *parser) parseClassChar(into *CharSet) (c byte, isSet bool, err error) {
	if !p.more() {
		return 0, false, p.errf("missing closing ]")
	}
	c = p.peek()
	if c == ']' {
		return 0, false, p.errf("unexpected ]")
	}
	p.pos++
	if c != '\\' {
		return c, false, nil
	}
	if !p.more() {
		return 0, false, p.errf("trailing backslash")
	}
	e := p.peek()
	if set, ok := escapeSet(e); ok {
		p.pos++
		if into == nil {
			return 0, true, nil
		}
		into.AddSet(&set)
		return 0, true, nil
	}
	if isAlnum(e) {
		return 0, false, p.errf("unsupported escape \\%c", e)
	}
	p.pos++
	return e, false, nil
}

// parseQuantifier parses a quantifier at the cursor and wraps atom in it.
func (p *parser) parseQuantifier(atom *Node) (*Node, error) {
	min, max := 0, Unbounded
	switch p.peek() {
	case '*':
		p.pos++
	case '+':
		min = 1
		p.pos++
	case '?':
		max = 1
		p.pos++
	case '{':
		p.pos++
		n, ok := p.parseInt()
		if !ok {
			return nil, p.errf("invalid repeat count")
		}
		min, max = n, n
		if p.more() && p.peek() == ',' {
			p.pos++
			if p.more() && p.peek() == '}' {
				max = Unbounded
			} else if m, ok := p.parseInt(); ok {
				max = m
			} else {
				return nil, p.errf("invalid repeat count")
			}
		}
		if !p.more() || p.peek() != '}' {
			return nil, p.errf("invalid repeat count")
		}
		p.pos++
		if max != Unbounded && max < min {
			return nil, p.errf("invalid repeat count: max < min")
		}
		if min > MaxRepeat || max > MaxRepeat {
			return nil, p.errf("repeat count too large (limit %d)", MaxRepeat)
		}
	}
	if p.more() {
		switch p.peek() {
		case '*', '+', '?', '{':
			return nil, p.errf("nested repetition operator")
		}
	}
	return &Node{Kind: KindRep, Subs: []*Node{atom}, Min: min, Max: max}, nil
}

func (p *parser) parseInt() (int, bool) {
	start := p.pos
	n := 0
	for p.more() && p.peek() >= '0' && p.peek() <= '9' {
		n = n*10 + int(p.peek()-'0')
		if n > 1<<20 {
			n = 1 << 20
		}
		p.pos++
	}
	return n, p.pos > start
}
