// Package parser reads Datalog source text into an ast.Program.
//
// Parsing is a single pass over the bytes: the lexer feeds the recursive
// descent parser one token at a time, and constants, predicates and variables
// are interned as they are seen. When the whole input has been read the
// constants are sorted into the language's total order and every constant
// reference is renumbered to its rank.
package parser

import (
	"fmt"
	"sort"
	"strconv"

	"datalog/ast"
)

// SyntaxError reports malformed input.
type SyntaxError struct {
	Line int
	Msg  string
}

func (e *SyntaxError) Error() string { return fmt.Sprintf("line %d: %s", e.Line+1, e.Msg) }

// Parse parses a complete program.
func Parse(src []byte) (*ast.Program, error) {
	p := &parser{
		lex:       lexer{src: src},
		prog:      &ast.Program{},
		predIDs:   map[ast.Pred]int{},
		identIDs:  map[string]int{},
		intIDs:    map[int64]int{},
		rawConsts: nil,
	}
	if err := p.advance(); err != nil {
		return nil, err
	}
	for p.tok.kind != tEOF {
		if err := p.clause(); err != nil {
			return nil, err
		}
	}
	p.renumber()
	return p.prog, nil
}

type parser struct {
	lex  lexer
	tok  token // current token
	prog *ast.Program

	predIDs   map[ast.Pred]int
	identIDs  map[string]int
	intIDs    map[int64]int
	rawConsts []ast.Constant // constants in first-seen order

	vars    map[string]int // per-clause variable slots
	numVars int
}

func (p *parser) advance() error {
	t, err := p.lex.next()
	if err != nil {
		return err
	}
	p.tok = t
	return nil
}

func (p *parser) errf(format string, args ...any) error {
	return &SyntaxError{Line: p.tok.line, Msg: fmt.Sprintf(format, args...)}
}

func (p *parser) expect(k tokKind) error {
	if p.tok.kind != k {
		return p.errf("expected %v, found %v", k, p.tok.kind)
	}
	return p.advance()
}

func (p *parser) resetClause() {
	p.vars = map[string]int{}
	p.numVars = 0
}

// clause = fact | rule | query.
func (p *parser) clause() error {
	p.resetClause()
	if p.tok.kind == tQuery {
		if err := p.advance(); err != nil {
			return err
		}
		a, err := p.atom()
		if err != nil {
			return err
		}
		if err := p.expect(tDot); err != nil {
			return err
		}
		p.prog.Queries = append(p.prog.Queries, a)
		return nil
	}
	head, err := p.atom()
	if err != nil {
		return err
	}
	rule := ast.Rule{Head: head}
	if p.tok.kind == tNeck {
		if err := p.advance(); err != nil {
			return err
		}
		for {
			lit, err := p.literal()
			if err != nil {
				return err
			}
			rule.Body = append(rule.Body, lit)
			if p.tok.kind != tComma {
				break
			}
			if err := p.advance(); err != nil {
				return err
			}
		}
	}
	if err := p.expect(tDot); err != nil {
		return err
	}
	rule.NumVars = p.numVars
	p.prog.Rules = append(p.prog.Rules, rule)
	return nil
}

// literal = atom | "not" atom | term cmpop term.
func (p *parser) literal() (ast.Literal, error) {
	if p.tok.kind == tNot {
		if err := p.advance(); err != nil {
			return ast.Literal{}, err
		}
		a, err := p.atom()
		return ast.Literal{Kind: ast.Negative, Atom: a}, err
	}
	if p.tok.kind == tIdent {
		// An identifier followed by "(" starts an atom; otherwise it is a
		// constant on the left of a comparison. Peek with a copy of the lexer.
		save := p.lex
		nxt, err := p.lex.next()
		p.lex = save
		if err != nil {
			return ast.Literal{}, err
		}
		if nxt.kind == tLParen {
			a, err := p.atom()
			return ast.Literal{Kind: ast.Positive, Atom: a}, err
		}
	}
	left, err := p.term()
	if err != nil {
		return ast.Literal{}, err
	}
	var op ast.CmpOp
	switch p.tok.kind {
	case tEq:
		op = ast.Eq
	case tNe:
		op = ast.Ne
	case tLt:
		op = ast.Lt
	case tLe:
		op = ast.Le
	case tGt:
		op = ast.Gt
	case tGe:
		op = ast.Ge
	default:
		return ast.Literal{}, p.errf("expected comparison operator, found %v", p.tok.kind)
	}
	if err := p.advance(); err != nil {
		return ast.Literal{}, err
	}
	right, err := p.term()
	if err != nil {
		return ast.Literal{}, err
	}
	return ast.Literal{Kind: ast.Comparison, Op: op, Left: left, Right: right}, nil
}

// atom = identifier "(" term ("," term)* ")".
func (p *parser) atom() (ast.Atom, error) {
	if p.tok.kind != tIdent {
		return ast.Atom{}, p.errf("expected predicate name, found %v", p.tok.kind)
	}
	name := p.tok.text
	if err := p.advance(); err != nil {
		return ast.Atom{}, err
	}
	if err := p.expect(tLParen); err != nil {
		return ast.Atom{}, err
	}
	var args []ast.Term
	for {
		t, err := p.term()
		if err != nil {
			return ast.Atom{}, err
		}
		args = append(args, t)
		if p.tok.kind != tComma {
			break
		}
		if err := p.advance(); err != nil {
			return ast.Atom{}, err
		}
	}
	if err := p.expect(tRParen); err != nil {
		return ast.Atom{}, err
	}
	key := ast.Pred{Name: name, Arity: len(args)}
	id, ok := p.predIDs[key]
	if !ok {
		id = len(p.prog.Preds)
		p.predIDs[key] = id
		p.prog.Preds = append(p.prog.Preds, key)
	}
	return ast.Atom{Pred: id, Args: args}, nil
}

// term = constant | variable | "_".
func (p *parser) term() (ast.Term, error) {
	t := p.tok
	switch t.kind {
	case tVar:
		id, ok := p.vars[t.text]
		if !ok {
			id = p.numVars
			p.numVars++
			p.vars[t.text] = id
		}
		return ast.Term{IsVar: true, ID: id}, p.advance()
	case tAnon:
		id := p.numVars
		p.numVars++
		return ast.Term{IsVar: true, ID: id}, p.advance()
	case tIdent:
		id, ok := p.identIDs[t.text]
		if !ok {
			id = len(p.rawConsts)
			p.identIDs[t.text] = id
			p.rawConsts = append(p.rawConsts, ast.Constant{Name: t.text})
		}
		return ast.Term{ID: id}, p.advance()
	case tInt:
		v, err := strconv.ParseInt(t.text, 10, 64)
		if err != nil {
			return ast.Term{}, p.errf("bad integer %q", t.text)
		}
		id, ok := p.intIDs[v]
		if !ok {
			id = len(p.rawConsts)
			p.intIDs[v] = id
			p.rawConsts = append(p.rawConsts, ast.Constant{IsInt: true, Int: v})
		}
		return ast.Term{ID: id}, p.advance()
	}
	return ast.Term{}, p.errf("expected a term, found %v", t.kind)
}

// renumber sorts the constants into the language order and rewrites every
// constant reference from first-seen id to rank.
func (p *parser) renumber() {
	n := len(p.rawConsts)
	order := make([]int, n) // order[rank] = raw id
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(a, b int) bool {
		return ast.Compare(p.rawConsts[order[a]], p.rawConsts[order[b]]) < 0
	})
	rank := make([]int, n)
	consts := make([]ast.Constant, n)
	for r, raw := range order {
		rank[raw] = r
		consts[r] = p.rawConsts[raw]
	}
	p.prog.Consts = consts
	fix := func(t *ast.Term) {
		if !t.IsVar {
			t.ID = rank[t.ID]
		}
	}
	fixAtom := func(a *ast.Atom) {
		for i := range a.Args {
			fix(&a.Args[i])
		}
	}
	for i := range p.prog.Rules {
		r := &p.prog.Rules[i]
		fixAtom(&r.Head)
		for j := range r.Body {
			l := &r.Body[j]
			if l.Kind == ast.Comparison {
				fix(&l.Left)
				fix(&l.Right)
			} else {
				fixAtom(&l.Atom)
			}
		}
	}
	for i := range p.prog.Queries {
		fixAtom(&p.prog.Queries[i])
	}
}
