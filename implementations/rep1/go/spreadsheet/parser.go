package spreadsheet

import (
	"fmt"
	"strconv"
)

// maxDepth bounds parser recursion so hostile input cannot exhaust the stack.
const maxDepth = 10000

type parser struct {
	toks   []token
	pos    int
	depth  int
	lookup func(cellKey) *cell // resolves (creating if needed) a cell
	badRef bool                // an invalid reference was seen
	deps   []*cell             // dependencies in order of appearance (may repeat)
}

// formula is a parsed formula: a syntax tree plus its dependencies.
type formula struct {
	root   node
	badRef bool
	deps   []*cell // distinct, in order of first appearance
}

// parseFormula parses the text after '=' into a formula, resolving cell
// references through lookup.
func parseFormula(src string, lookup func(cellKey) *cell) (*formula, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks, lookup: lookup}
	root, err := p.parseCmp()
	if err != nil {
		return nil, err
	}
	if t := p.peek(); t.kind != tokEOF {
		return nil, fmt.Errorf("unexpected %q at offset %d", t.text, t.pos)
	}
	if p.badRef {
		return &formula{badRef: true}, nil
	}
	f := &formula{root: root}
	seen := make(map[*cell]struct{}, len(p.deps))
	for _, d := range p.deps {
		if _, dup := seen[d]; !dup {
			seen[d] = struct{}{}
			f.deps = append(f.deps, d)
		}
	}
	return f, nil
}

func (p *parser) peek() token { return p.toks[p.pos] }
func (p *parser) next() token {
	t := p.toks[p.pos]
	if t.kind != tokEOF {
		p.pos++
	}
	return t
}

func (p *parser) isOp(s string) bool {
	t := p.peek()
	return t.kind == tokOp && t.text == s
}

func (p *parser) expect(s string) error {
	t := p.next()
	if t.kind != tokOp || t.text != s {
		return fmt.Errorf("expected %q at offset %d", s, t.pos)
	}
	return nil
}

func (p *parser) enter() error {
	p.depth++
	if p.depth > maxDepth {
		return fmt.Errorf("formula nested too deeply")
	}
	return nil
}

func (p *parser) parseCmp() (node, error) {
	left, err := p.parseCat()
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		if t.kind != tokOp {
			return left, nil
		}
		switch t.text {
		case "=", "<>", "<", ">", "<=", ">=":
		default:
			return left, nil
		}
		p.next()
		right, err := p.parseCat()
		if err != nil {
			return nil, err
		}
		left = &cmpNode{op: t.text, l: left, r: right}
	}
}

func (p *parser) parseCat() (node, error) {
	left, err := p.parseAdd()
	if err != nil {
		return nil, err
	}
	for p.isOp("&") {
		p.next()
		right, err := p.parseAdd()
		if err != nil {
			return nil, err
		}
		left = &catNode{l: left, r: right}
	}
	return left, nil
}

func (p *parser) parseAdd() (node, error) {
	left, err := p.parseMul()
	if err != nil {
		return nil, err
	}
	for p.isOp("+") || p.isOp("-") {
		op := p.next().text[0]
		right, err := p.parseMul()
		if err != nil {
			return nil, err
		}
		left = &arithNode{op: op, l: left, r: right}
	}
	return left, nil
}

func (p *parser) parseMul() (node, error) {
	left, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for p.isOp("*") || p.isOp("/") {
		op := p.next().text[0]
		right, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		left = &arithNode{op: op, l: left, r: right}
	}
	return left, nil
}

func (p *parser) parseUnary() (node, error) {
	if err := p.enter(); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	if p.isOp("-") {
		p.next()
		x, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return &negNode{x: x}, nil
	}
	return p.parsePrimary()
}

// refKey converts a REF token to a cell key; ok is false for invalid
// references (too many letters, row out of range, leading zero).
func refKey(text string) (cellKey, bool) { return parseCellName(text) }

func (p *parser) parsePrimary() (node, error) {
	t := p.next()
	switch t.kind {
	case tokNum:
		f, err := strconv.ParseFloat(t.text, 64)
		if err != nil && !isRangeErr(err) {
			return nil, err
		}
		return &numNode{v: f}, nil
	case tokStr:
		return &strNode{s: t.text}, nil
	case tokRef:
		key, ok := refKey(t.text)
		if !ok {
			p.badRef = true
			return &numNode{}, nil
		}
		c := p.lookup(key)
		p.deps = append(p.deps, c)
		return &refNode{c: c}, nil
	case tokOp:
		if t.text == "(" {
			x, err := p.parseExprNested()
			if err != nil {
				return nil, err
			}
			if err := p.expect(")"); err != nil {
				return nil, err
			}
			return x, nil
		}
	case tokIdent:
		return p.parseCall(t)
	}
	return nil, fmt.Errorf("unexpected %q at offset %d", t.text, t.pos)
}

func isRangeErr(err error) bool {
	ne, ok := err.(*strconv.NumError)
	return ok && ne.Err == strconv.ErrRange
}

func (p *parser) parseExprNested() (node, error) {
	if err := p.enter(); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	return p.parseCmp()
}

func (p *parser) parseCall(name token) (node, error) {
	if err := p.expect("("); err != nil {
		return nil, err
	}
	if err := p.enter(); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	if name.text == "IF" {
		c, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		if err := p.expect(","); err != nil {
			return nil, err
		}
		a, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		if err := p.expect(","); err != nil {
			return nil, err
		}
		b, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		if err := p.expect(")"); err != nil {
			return nil, err
		}
		return &ifNode{cond: c, a: a, b: b}, nil
	}
	var fn aggFunc
	switch name.text {
	case "SUM":
		fn = aggSum
	case "MIN":
		fn = aggMin
	case "MAX":
		fn = aggMax
	case "AVG":
		fn = aggAvg
	case "COUNT":
		fn = aggCount
	default:
		return nil, fmt.Errorf("unknown function %q at offset %d", name.text, name.pos)
	}
	agg := &aggNode{fn: fn}
	for {
		arg, err := p.parseAggArg()
		if err != nil {
			return nil, err
		}
		agg.args = append(agg.args, arg)
		if p.isOp(",") {
			p.next()
			continue
		}
		break
	}
	if err := p.expect(")"); err != nil {
		return nil, err
	}
	return agg, nil
}

func (p *parser) parseAggArg() (aggArg, error) {
	// A range is REF ":" REF; otherwise an ordinary expression.
	if p.peek().kind == tokRef && p.toks[p.pos+1].kind == tokOp && p.toks[p.pos+1].text == ":" {
		a := p.next()
		p.next()
		b := p.next()
		if b.kind != tokRef {
			return aggArg{}, fmt.Errorf("expected reference after ':' at offset %d", b.pos)
		}
		ka, okA := refKey(a.text)
		kb, okB := refKey(b.text)
		if !okA || !okB {
			p.badRef = true
			return aggArg{}, nil
		}
		return aggArg{cells: p.expandRange(ka, kb)}, nil
	}
	e, err := p.parseCmp()
	return aggArg{expr: e}, err
}

// expandRange returns the cells of the rectangle spanned by a and b in
// row-major order, and records them as dependencies.
func (p *parser) expandRange(a, b cellKey) []*cell {
	r1, r2 := min(a.row(), b.row()), max(a.row(), b.row())
	c1, c2 := min(a.col(), b.col()), max(a.col(), b.col())
	cells := make([]*cell, 0, (r2-r1+1)*(c2-c1+1))
	for r := r1; r <= r2; r++ {
		for c := c1; c <= c2; c++ {
			cells = append(cells, p.lookup(makeKey(r, c)))
		}
	}
	p.deps = append(p.deps, cells...)
	return cells
}
