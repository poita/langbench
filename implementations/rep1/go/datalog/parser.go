package datalog

import "slices"

// maxArity bounds predicate arity; index column sets are stored in a uint64.
const maxArity = 64

// Parse reads a complete program. Every constant is interned and renumbered so
// that constant ids follow the constant order; every predicate (name and arity
// together) gets a dense id. Parse only checks syntax; see [Program.Check] for
// safety and stratification.
func Parse(src []byte) (*Program, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{
		toks:     toks,
		prog:     &Program{},
		constIDs: map[Constant]int{},
		predIDs:  map[Predicate]int{},
		vars:     map[string]int{},
	}
	for p.cur().kind != tEOF {
		if err := p.clause(); err != nil {
			return nil, err
		}
	}
	p.renumberConstants()
	return p.prog, nil
}

type parser struct {
	toks     []token
	pos      int
	prog     *Program
	constIDs map[Constant]int
	predIDs  map[Predicate]int
	vars     map[string]int // variable name -> slot, per clause
	nvars    int
}

func (p *parser) cur() token { return p.toks[p.pos] }

func (p *parser) peek() token {
	if p.pos+1 < len(p.toks) {
		return p.toks[p.pos+1]
	}
	return p.toks[len(p.toks)-1]
}

func (p *parser) errorf(t token, msg string) error {
	return &SyntaxError{Line: t.line, Col: t.col, Msg: msg}
}

func (p *parser) expect(k tokKind) (token, error) {
	t := p.cur()
	if t.kind != k {
		return t, p.errorf(t, "expected "+k.String()+", found "+t.kind.String())
	}
	p.pos++
	return t, nil
}

func (p *parser) resetClause() {
	clear(p.vars)
	p.nvars = 0
}

func (p *parser) clause() error {
	p.resetClause()
	first := p.cur()
	if first.kind == tQuery {
		p.pos++
		a, err := p.atom()
		if err != nil {
			return err
		}
		if _, err := p.expect(tDot); err != nil {
			return err
		}
		p.prog.Queries = append(p.prog.Queries, Query{Atom: a, NumVars: p.nvars, Line: first.line})
		return nil
	}
	head, err := p.atom()
	if err != nil {
		return err
	}
	r := Rule{Head: head, Line: first.line}
	if p.cur().kind == tImplies {
		p.pos++
		for {
			l, err := p.literal()
			if err != nil {
				return err
			}
			r.Body = append(r.Body, l)
			if p.cur().kind != tComma {
				break
			}
			p.pos++
		}
	}
	if _, err := p.expect(tDot); err != nil {
		return err
	}
	r.NumVars = p.nvars
	p.prog.Rules = append(p.prog.Rules, r)
	return nil
}

func (p *parser) literal() (Literal, error) {
	t := p.cur()
	switch {
	case t.kind == tNot:
		p.pos++
		a, err := p.atom()
		return Literal{Kind: Negative, Atom: a}, err
	case t.kind == tIdent && p.peek().kind == tLParen:
		a, err := p.atom()
		return Literal{Kind: Positive, Atom: a}, err
	}
	left, err := p.term()
	if err != nil {
		return Literal{}, err
	}
	var op CmpOp
	switch p.cur().kind {
	case tEQ:
		op = OpEq
	case tNE:
		op = OpNe
	case tLT:
		op = OpLt
	case tLE:
		op = OpLe
	case tGT:
		op = OpGt
	case tGE:
		op = OpGe
	default:
		return Literal{}, p.errorf(p.cur(), "expected comparison operator, found "+p.cur().kind.String())
	}
	p.pos++
	right, err := p.term()
	if err != nil {
		return Literal{}, err
	}
	return Literal{Kind: Comparison, Op: op, Left: left, Right: right}, nil
}

func (p *parser) atom() (Atom, error) {
	name, err := p.expect(tIdent)
	if err != nil {
		return Atom{}, err
	}
	if _, err := p.expect(tLParen); err != nil {
		return Atom{}, err
	}
	var args []Term
	for {
		t, err := p.term()
		if err != nil {
			return Atom{}, err
		}
		args = append(args, t)
		if p.cur().kind != tComma {
			break
		}
		p.pos++
	}
	if _, err := p.expect(tRParen); err != nil {
		return Atom{}, err
	}
	if len(args) > maxArity {
		return Atom{}, p.errorf(name, "too many arguments")
	}
	pred := Predicate{Name: name.text, Arity: len(args)}
	id, ok := p.predIDs[pred]
	if !ok {
		id = len(p.prog.Preds)
		p.predIDs[pred] = id
		p.prog.Preds = append(p.prog.Preds, pred)
	}
	return Atom{Pred: id, Args: args}, nil
}

func (p *parser) term() (Term, error) {
	t := p.cur()
	switch t.kind {
	case tIdent:
		p.pos++
		return Term{Index: p.constant(Sym(t.text))}, nil
	case tInt:
		p.pos++
		return Term{Index: p.constant(Int(t.num))}, nil
	case tVar:
		p.pos++
		slot, ok := p.vars[t.text]
		if !ok {
			slot = p.nvars
			p.nvars++
			p.vars[t.text] = slot
		}
		return Term{IsVar: true, Index: slot}, nil
	case tAnon:
		p.pos++
		slot := p.nvars
		p.nvars++
		return Term{IsVar: true, Index: slot}, nil
	}
	return Term{}, p.errorf(t, "expected term, found "+t.kind.String())
}

func (p *parser) constant(c Constant) int {
	id, ok := p.constIDs[c]
	if !ok {
		id = len(p.prog.Consts)
		p.constIDs[c] = id
		p.prog.Consts = append(p.prog.Consts, c)
	}
	return id
}

// renumberConstants sorts the constants into the SPEC order and rewrites every
// constant term to its rank.
func (p *parser) renumberConstants() {
	prog := p.prog
	order := make([]int, len(prog.Consts))
	for i := range order {
		order[i] = i
	}
	slices.SortFunc(order, func(a, b int) int { return prog.Consts[a].Compare(prog.Consts[b]) })
	rank := make([]int, len(order))
	sorted := make([]Constant, len(order))
	for r, old := range order {
		rank[old] = r
		sorted[r] = prog.Consts[old]
	}
	prog.Consts = sorted
	fix := func(args []Term) {
		for i, t := range args {
			if !t.IsVar {
				args[i].Index = rank[t.Index]
			}
		}
	}
	for i := range prog.Rules {
		r := &prog.Rules[i]
		fix(r.Head.Args)
		for j := range r.Body {
			l := &r.Body[j]
			if l.Kind == Comparison {
				pair := []Term{l.Left, l.Right}
				fix(pair)
				l.Left, l.Right = pair[0], pair[1]
			} else {
				fix(l.Atom.Args)
			}
		}
	}
	for i := range prog.Queries {
		fix(prog.Queries[i].Atom.Args)
	}
}
