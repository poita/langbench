package datalog

import (
	"fmt"
	"sort"
)

type predKey struct {
	name  string
	arity int
}

type parser struct {
	lex lexer
	cur token

	prog   *Program
	preds  map[predKey]int32
	ints   map[int64]int32
	syms   map[string]int32
	vars   map[string]int32 // variable name -> slot, per clause
	nslots int
}

// Parse reads a whole program. Predicates and constants are interned and the
// constants renumbered so that ids follow the language's total order.
// Syntax errors are reported as *[SyntaxError].
func Parse(src []byte) (*Program, error) {
	p := &parser{
		lex:   lexer{src: src, line: 1},
		prog:  &Program{},
		preds: make(map[predKey]int32),
		ints:  make(map[int64]int32),
		syms:  make(map[string]int32),
		vars:  make(map[string]int32),
	}
	if err := p.advance(); err != nil {
		return nil, err
	}
	for p.cur.kind != tEOF {
		if err := p.clause(); err != nil {
			return nil, err
		}
	}
	p.prog.sortConstants()
	return p.prog, nil
}

func (p *parser) advance() error {
	t, err := p.lex.next()
	p.cur = t
	return err
}

func (p *parser) errorf(format string, args ...any) error {
	return &SyntaxError{Line: p.cur.line, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) expect(k tokKind, what string) error {
	if p.cur.kind != k {
		return p.errorf("expected %s", what)
	}
	return p.advance()
}

func (p *parser) clause() error {
	clear(p.vars)
	p.nslots = 0
	if p.cur.kind == tQuery {
		if err := p.advance(); err != nil {
			return err
		}
		a, err := p.atom()
		if err != nil {
			return err
		}
		if err := p.expect(tDot, "'.'"); err != nil {
			return err
		}
		p.prog.queries = append(p.prog.queries, query{atom: a, numVars: p.nslots})
		return nil
	}
	head, err := p.atom()
	if err != nil {
		return err
	}
	r := rule{head: head}
	switch p.cur.kind {
	case tDot:
		if err := p.advance(); err != nil {
			return err
		}
	case tImplies:
		if err := p.advance(); err != nil {
			return err
		}
		for {
			l, err := p.literal()
			if err != nil {
				return err
			}
			r.body = append(r.body, l)
			if p.cur.kind != tComma {
				break
			}
			if err := p.advance(); err != nil {
				return err
			}
		}
		if err := p.expect(tDot, "'.' or ','"); err != nil {
			return err
		}
	default:
		return p.errorf("expected '.' or ':-'")
	}
	r.numVars = p.nslots
	p.prog.rules = append(p.prog.rules, r)
	return nil
}

func (p *parser) literal() (literal, error) {
	switch p.cur.kind {
	case tNot:
		if err := p.advance(); err != nil {
			return literal{}, err
		}
		a, err := p.atom()
		return literal{kind: litNeg, atom: a}, err
	case tIdent:
		name := p.cur.text
		if err := p.advance(); err != nil {
			return literal{}, err
		}
		if p.cur.kind == tLParen {
			a, err := p.atomArgs(name)
			return literal{kind: litPos, atom: a}, err
		}
		return p.comparison(term{id: p.sym(name)})
	}
	l, err := p.term()
	if err != nil {
		return literal{}, err
	}
	return p.comparison(l)
}

func (p *parser) comparison(l term) (literal, error) {
	var op cmpOp
	switch p.cur.kind {
	case tLT:
		op = opLT
	case tLE:
		op = opLE
	case tGT:
		op = opGT
	case tGE:
		op = opGE
	case tEQ:
		op = opEQ
	case tNE:
		op = opNE
	default:
		return literal{}, p.errorf("expected comparison operator")
	}
	if err := p.advance(); err != nil {
		return literal{}, err
	}
	r, err := p.term()
	return literal{kind: litCmp, op: op, l: l, r: r}, err
}

func (p *parser) atom() (atom, error) {
	if p.cur.kind != tIdent {
		return atom{}, p.errorf("expected predicate name")
	}
	name := p.cur.text
	if err := p.advance(); err != nil {
		return atom{}, err
	}
	return p.atomArgs(name)
}

// atomArgs parses "(" term {"," term} ")" for predicate name.
func (p *parser) atomArgs(name string) (atom, error) {
	if err := p.expect(tLParen, "'('"); err != nil {
		return atom{}, err
	}
	var args []term
	for {
		t, err := p.term()
		if err != nil {
			return atom{}, err
		}
		args = append(args, t)
		if p.cur.kind != tComma {
			break
		}
		if err := p.advance(); err != nil {
			return atom{}, err
		}
	}
	if err := p.expect(tRParen, "')' or ','"); err != nil {
		return atom{}, err
	}
	return atom{pred: p.pred(name, len(args)), args: args}, nil
}

func (p *parser) term() (term, error) {
	var t term
	switch p.cur.kind {
	case tIdent:
		t = term{id: p.sym(p.cur.text)}
	case tInt:
		id, ok := p.ints[p.cur.num]
		if !ok {
			id = int32(len(p.prog.consts))
			p.prog.consts = append(p.prog.consts, Int(p.cur.num))
			p.ints[p.cur.num] = id
		}
		t = term{id: id}
	case tVar:
		slot, ok := p.vars[p.cur.text]
		if !ok {
			slot = int32(p.nslots)
			p.nslots++
			p.vars[p.cur.text] = slot
		}
		t = term{isVar: true, id: slot}
	case tAnon:
		t = term{isVar: true, id: int32(p.nslots)}
		p.nslots++
	default:
		return t, p.errorf("expected a term")
	}
	return t, p.advance()
}

func (p *parser) sym(name string) int32 {
	id, ok := p.syms[name]
	if !ok {
		id = int32(len(p.prog.consts))
		p.prog.consts = append(p.prog.consts, Sym(name))
		p.syms[name] = id
	}
	return id
}

func (p *parser) pred(name string, arity int) int32 {
	k := predKey{name, arity}
	id, ok := p.preds[k]
	if !ok {
		id = int32(len(p.prog.preds))
		p.prog.preds = append(p.prog.preds, predInfo{name, arity})
		p.preds[k] = id
	}
	return id
}

// sortConstants renumbers constants so that id order is the language order,
// making every later comparison a plain integer comparison.
func (p *Program) sortConstants() {
	n := len(p.consts)
	order := make([]int32, n) // order[rank] = old id
	for i := range order {
		order[i] = int32(i)
	}
	sort.Slice(order, func(i, j int) bool {
		return p.consts[order[i]].Compare(p.consts[order[j]]) < 0
	})
	rank := make([]int32, n) // rank[old id] = new id
	sorted := make([]Value, n)
	for r, old := range order {
		rank[old] = int32(r)
		sorted[r] = p.consts[old]
	}
	p.consts = sorted
	remap := func(ts []term) {
		for i := range ts {
			if !ts[i].isVar {
				ts[i].id = rank[ts[i].id]
			}
		}
	}
	for i := range p.rules {
		r := &p.rules[i]
		remap(r.head.args)
		for j := range r.body {
			l := &r.body[j]
			remap(l.atom.args)
			if l.kind == litCmp {
				pair := []term{l.l, l.r}
				remap(pair)
				l.l, l.r = pair[0], pair[1]
			}
		}
	}
	for i := range p.queries {
		remap(p.queries[i].atom.args)
	}
}
