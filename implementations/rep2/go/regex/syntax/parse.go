package syntax

import "fmt"

// Limits enforced by the parser.
const (
	// MaxRepeat is the largest count allowed in a {n,m} quantifier.
	MaxRepeat = 1000
	// MaxDepth is the deepest allowed nesting of groups.
	MaxDepth = 500
)

// Error describes a syntax error in a pattern.
type Error struct {
	Pattern string // the offending pattern
	Pos     int    // byte offset of the error within Pattern
	Msg     string // description of the problem
}

func (e *Error) Error() string {
	return fmt.Sprintf("regex: invalid pattern %q at offset %d: %s", e.Pattern, e.Pos, e.Msg)
}

// Parse parses pattern and returns its syntax tree together with the number of
// capturing groups. Groups are numbered from 1 by the position of their '('.
func Parse(pattern string) (root *Node, groups int, err error) {
	p := &parser{src: pattern}
	root, err = p.parseRegex()
	if err != nil {
		return nil, 0, err
	}
	if p.pos < len(p.src) { // only an unmatched ')' stops parseRegex early
		return nil, 0, p.errf("unmatched )")
	}
	return root, p.groups, nil
}

type parser struct {
	src    string
	pos    int
	groups int
	depth  int
}

func (p *parser) errf(format string, args ...any) error {
	return &Error{Pattern: p.src, Pos: p.pos, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) more() bool { return p.pos < len(p.src) }

// regex := branch ('|' branch)*
func (p *parser) parseRegex() (*Node, error) {
	var branches []*Node
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
	return &Node{Kind: Alternate, Subs: branches}, nil
}

// branch := piece*
func (p *parser) parseBranch() (*Node, error) {
	var pieces []*Node
	for p.more() {
		c := p.src[p.pos]
		if c == '|' || c == ')' {
			break
		}
		piece, err := p.parsePiece()
		if err != nil {
			return nil, err
		}
		pieces = append(pieces, piece)
	}
	switch len(pieces) {
	case 0:
		return &Node{Kind: Empty}, nil
	case 1:
		return pieces[0], nil
	}
	return &Node{Kind: Concat, Subs: pieces}, nil
}

// piece := atom quantifier?
func (p *parser) parsePiece() (*Node, error) {
	atom, err := p.parseAtom()
	if err != nil {
		return nil, err
	}
	if !p.more() {
		return atom, nil
	}
	min, max, ok, err := p.parseQuantifier()
	if err != nil {
		return nil, err
	}
	if !ok {
		return atom, nil
	}
	if atom.Kind == StartAnchor || atom.Kind == EndAnchor {
		return nil, p.errf("quantifier after anchor")
	}
	n := &Node{Kind: Repeat, Subs: []*Node{atom}, Min: min, Max: max}
	if p.more() && isQuantStart(p.src[p.pos]) {
		return nil, p.errf("quantifier after quantifier")
	}
	return n, nil
}

func isQuantStart(c byte) bool { return c == '*' || c == '+' || c == '?' || c == '{' }

// parseQuantifier parses a quantifier at the current position, if any.
func (p *parser) parseQuantifier() (min, max int, ok bool, err error) {
	switch p.src[p.pos] {
	case '*':
		p.pos++
		return 0, Unbounded, true, nil
	case '+':
		p.pos++
		return 1, Unbounded, true, nil
	case '?':
		p.pos++
		return 0, 1, true, nil
	case '{':
		p.pos++
		min, err = p.parseInt()
		if err != nil {
			return
		}
		max = min
		if p.more() && p.src[p.pos] == ',' {
			p.pos++
			if p.more() && p.src[p.pos] == '}' {
				max = Unbounded
			} else if max, err = p.parseInt(); err != nil {
				return
			}
		}
		if !p.more() || p.src[p.pos] != '}' {
			return 0, 0, false, p.errf("expected } in quantifier")
		}
		p.pos++
		if max != Unbounded && max < min {
			return 0, 0, false, p.errf("quantifier minimum exceeds maximum")
		}
		return min, max, true, nil
	}
	return 0, 0, false, nil
}

func (p *parser) parseInt() (int, error) {
	start, n := p.pos, 0
	for p.more() && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		n = n*10 + int(p.src[p.pos]-'0')
		if n > MaxRepeat {
			return 0, p.errf("repeat count exceeds %d", MaxRepeat)
		}
		p.pos++
	}
	if p.pos == start {
		return 0, p.errf("expected number in quantifier")
	}
	return n, nil
}

// atom := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
func (p *parser) parseAtom() (*Node, error) {
	c := p.src[p.pos]
	switch c {
	case '.':
		p.pos++
		return &Node{Kind: AnyChar}, nil
	case '^':
		p.pos++
		return &Node{Kind: StartAnchor}, nil
	case '$':
		p.pos++
		return &Node{Kind: EndAnchor}, nil
	case '[':
		return p.parseClass()
	case '(':
		return p.parseGroup()
	case '\\':
		return p.parseEscape()
	case '*', '+', '?', '{':
		return nil, p.errf("quantifier %q has nothing to repeat", c)
	case ']', '}':
		return nil, p.errf("unexpected %q", c)
	}
	p.pos++
	return &Node{Kind: Literal, Char: c}, nil
}

func (p *parser) parseGroup() (*Node, error) {
	if p.depth >= MaxDepth {
		return nil, p.errf("groups nested too deeply")
	}
	p.pos++ // '('
	p.groups++
	index := p.groups
	p.depth++
	inner, err := p.parseRegex()
	p.depth--
	if err != nil {
		return nil, err
	}
	if !p.more() || p.src[p.pos] != ')' {
		return nil, p.errf("missing )")
	}
	p.pos++
	return &Node{Kind: Group, Index: index, Subs: []*Node{inner}}, nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
}

func (p *parser) parseEscape() (*Node, error) {
	if p.pos+1 >= len(p.src) {
		return nil, p.errf("trailing backslash")
	}
	c := p.src[p.pos+1]
	if set, ok := escapeSet(c); ok {
		p.pos += 2
		return &Node{Kind: Class, Set: set}, nil
	}
	if isAlnum(c) {
		return nil, p.errf("unsupported escape \\%c", c)
	}
	p.pos += 2
	return &Node{Kind: Literal, Char: c}, nil
}

// class := '[' '^'? item+ ']'
func (p *parser) parseClass() (*Node, error) {
	p.pos++ // '['
	negate := false
	if p.more() && p.src[p.pos] == '^' {
		negate = true
		p.pos++
	}
	var set CharSet
	items := 0
	for {
		if !p.more() {
			return nil, p.errf("missing ]")
		}
		c := p.src[p.pos]
		if c == ']' && items > 0 {
			p.pos++
			break
		}
		items++
		if c == '\\' && p.pos+1 < len(p.src) {
			if es, ok := escapeSet(p.src[p.pos+1]); ok {
				set.Union(&es)
				p.pos += 2
				continue
			}
		}
		lo, err := p.classChar()
		if err != nil {
			return nil, err
		}
		// A '-' that is not the last character before ']' is a range operator.
		if p.pos+1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos+1] != ']' {
			p.pos++
			hi, err := p.classChar()
			if err != nil {
				return nil, err
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
	return &Node{Kind: Class, Set: set}, nil
}

// classChar reads a single character inside a class: any byte but '\' and
// ']', or '\' followed by a non-alphanumeric byte.
func (p *parser) classChar() (byte, error) {
	c := p.src[p.pos]
	switch {
	case c == ']':
		return 0, p.errf("empty class")
	case c != '\\':
		p.pos++
		return c, nil
	}
	if p.pos+1 >= len(p.src) {
		return 0, p.errf("trailing backslash")
	}
	e := p.src[p.pos+1]
	if isAlnum(e) {
		return 0, p.errf("unsupported escape \\%c in class", e)
	}
	p.pos += 2
	return e, nil
}
